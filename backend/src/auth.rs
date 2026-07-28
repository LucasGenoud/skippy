use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::{Algorithm, Argon2, Params, Version};
use rand_core::OsRng;
use axum::extract::FromRequestParts;
use axum::http::request::Parts;

use crate::AppState;
use crate::error::ApiError;

/// Argon2id — the hybrid variant, named rather than left to `Argon2::default()`
/// so a change in the crate's default can't quietly move us off it.
fn hasher() -> Argon2<'static> {
    Argon2::new(Algorithm::Argon2id, Version::V0x13, Params::default())
}

pub fn hash_password(password: &str) -> anyhow::Result<String> {
    let salt = SaltString::generate(&mut OsRng);
    Ok(hasher()
        .hash_password(password.as_bytes(), &salt)
        .map_err(|e| anyhow::anyhow!("hash failure: {e}"))?
        .to_string())
}

pub fn verify_password(password: &str, hash: &str) -> bool {
    let Ok(parsed) = PasswordHash::new(hash) else {
        return false;
    };
    // Variant, version and cost all come from the stored PHC string, not from
    // [`hasher`] — so hashes written before this pin keep verifying.
    hasher().verify_password(password.as_bytes(), &parsed).is_ok()
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

/// Extractor: the raw session token (used by logout).
pub struct SessionToken(pub String);

impl FromRequestParts<AppState> for SessionToken {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, _state: &AppState) -> Result<Self, ApiError> {
        bearer_token(parts).map(SessionToken).ok_or(ApiError::Unauthorized)
    }
}
