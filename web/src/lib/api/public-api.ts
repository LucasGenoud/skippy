import { pageOrigin } from "./base-url";
import { HttpApi } from "./http-api";

// The client the signed-out pages (public share, password reset) read through:
// pinned to the origin that served the page, since only that backend can
// answer for the token in its URL. Mirrors `_publicApi` in `main.dart`.
let publicApi: HttpApi | null = null;

export function getPublicApi(): HttpApi {
  publicApi ??= new HttpApi({ baseUrl: pageOrigin() });
  return publicApi;
}
