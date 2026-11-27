use argon2::password_hash::phc::PasswordHash;
use argon2::password_hash::{PasswordHasher, PasswordVerifier};
use argon2::{Algorithm, Argon2, Params, Version};
use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use std::sync::LazyLock;

use crate::AppState;
use crate::error::ApiError;
use crate::models::{NO_PASSWORD, TokenScope};

/// Argon2id, the hybrid variant, named rather than left to `Argon2::default()`
/// so a change in the crate's default can't quietly move us off it.
fn hasher() -> Argon2<'static> {
    Argon2::new(Algorithm::Argon2id, Version::V0x13, Params::default())
}

pub fn hash_password(password: &str) -> anyhow::Result<String> {
    // The salt is drawn from the OS random source by the hasher itself.
    let hash: PasswordHash = hasher()
        .hash_password(password.as_bytes())
        .map_err(|e| anyhow::anyhow!("hash failure: {e}"))?;
    Ok(hash.to_string())
}

pub fn verify_password(password: &str, hash: &str) -> bool {
    let Ok(parsed) = PasswordHash::new(hash) else {
        return false;
    };
    // Variant, version and cost all come from the stored PHC string, not from
    // [`hasher`], so hashes written before this pin keep verifying.
    hasher()
        .verify_password(password.as_bytes(), &parsed)
        .is_ok()
}

/// A real hash of nothing anyone knows, checked when there is no usable
/// stored hash, so a login costs one Argon2 run whether or not the account
/// exists and its timing does not say which addresses are registered.
static DECOY_HASH: LazyLock<String> = LazyLock::new(|| {
    let mut secret = [0u8; 32];
    getrandom::fill(&mut secret).expect("the OS random source is available");
    hash_password(&hex::encode(secret)).expect("argon2 hashes a fixed-size secret")
});

/// Password check for sign-in, constant-cost across missing accounts and
/// single sign-on accounts.
pub fn verify_login(password: &str, stored: Option<&str>) -> bool {
    let Some(hash) = stored.filter(|hash| *hash != NO_PASSWORD) else {
        verify_password(password, &DECOY_HASH);
        return false;
    };
    verify_password(password, hash)
}

fn bearer_token(parts: &Parts) -> Option<String> {
    parts
        .headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(str::to_string)
}

/// Extractor: the authenticated user's id, resolved from the Bearer token.
pub struct AuthUser(pub String);

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let token = bearer_token(parts).ok_or(ApiError::Unauthorized)?;
        let user_id = state
            .repo
            .user_id_for_token(&token)
            .await?
            .ok_or(ApiError::Unauthorized)?;
        Ok(AuthUser(user_id))
    }
}

/// Extractor for the MCP endpoint: the account behind a personal access
/// token, and what the token may do. Sessions are not accepted here, and
/// [`AuthUser`] accepts no personal token, so neither credential opens the
/// other's door.
pub struct TokenUser {
    pub user_id: String,
    pub scope: TokenScope,
    /// The one workspace the token reaches; None for all of them.
    pub workspace_id: Option<String>,
}

impl FromRequestParts<AppState> for TokenUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let token = bearer_token(parts).ok_or(ApiError::Unauthorized)?;
        let grant = state
            .repo
            .api_token_owner(&token)
            .await?
            .ok_or(ApiError::Unauthorized)?;
        Ok(TokenUser {
            user_id: grant.user_id,
            scope: grant.scope,
            workspace_id: grant.workspace_id,
        })
    }
}

/// Extractor: the raw session token (used by logout).
pub struct SessionToken(pub String);

impl FromRequestParts<AppState> for SessionToken {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, _state: &AppState) -> Result<Self, ApiError> {
        bearer_token(parts)
            .map(SessionToken)
            .ok_or(ApiError::Unauthorized)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes_written_by_argon2_0_5_still_verify() {
        let stored = "$argon2id$v=19$m=19456,t=2,p=1$BjWcY/XmBd4hIXqVMKWK9A$MMdBG6lEkK/OEscfhS8Jz0fDrRSbECI/gkGtrT+Gv/o";
        assert!(verify_password("hunter22", stored));
        assert!(!verify_password("hunter23", stored));
    }

    #[test]
    fn login_without_an_account_still_runs_argon2() {
        assert!(PasswordHash::new(&DECOY_HASH).is_ok());
        assert!(!verify_login("hunter22", None));
        assert!(!verify_login("", Some(crate::models::NO_PASSWORD)));
        let stored = hash_password("hunter22").unwrap();
        assert!(verify_login("hunter22", Some(&stored)));
    }
}
