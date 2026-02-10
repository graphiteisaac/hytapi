import gleam/dynamic/decode
import gleam/fetch
import gleam/http
import gleam/http/request
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/list
import gleam/uri
import hytapi/allowlist

pub fn redirect_uri(client_id: String, redirect_uri: String) {
  "https://discord.com/api/oauth2/authorize"
  <> "?client_id="
  <> uri.percent_encode(client_id)
  <> "&redirect_uri="
  <> uri.percent_encode(redirect_uri)
  <> "&response_type=code"
  <> "&scope=identify"
}

pub fn exchange_code_for_token(
  client_id: String,
  client_secret: String,
  redirect_uri: String,
  code: String,
) -> Promise(Result(String, fetch.FetchError)) {
  let body =
    "client_id="
    <> uri.percent_encode(client_id)
    <> "&client_secret="
    <> uri.percent_encode(client_secret)
    <> "&grant_type=authorization_code"
    <> "&code="
    <> uri.percent_encode(code)
    <> "&redirect_uri="
    <> uri.percent_encode(redirect_uri)

  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_host("discord.com")
    |> request.set_path("/api/oauth2/token")
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body(body)

  use resp <- promise.try_await(fetch.send(req))
  use resp <- promise.try_await(fetch.read_text_body(resp))

  case
    json.parse(resp.body, {
      use access_token <- decode.field("access_token", decode.string)
      decode.success(access_token)
    })
  {
    Ok(access_token) -> promise.resolve(Ok(access_token))
    Error(_) -> promise.resolve(Error(fetch.UnableToReadBody))
  }
}

pub fn token_user_id(token: String) -> Promise(Result(String, fetch.FetchError)) {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_host("discord.com")
    |> request.set_path("/api/users/@me")
    |> request.set_header("authorization", "Bearer " <> token)

  use resp <- promise.try_await(fetch.send(req))
  use resp <- promise.try_await(fetch.read_text_body(resp))

  case
    json.parse(resp.body, {
      use user_id <- decode.field("id", decode.string)
      decode.success(user_id)
    })
  {
    Ok(user_id) -> promise.resolve(Ok(user_id))
    Error(_) -> promise.resolve(Error(fetch.UnableToReadBody))
  }
}

pub fn is_user_allowed(user_id: String) -> Bool {
  list.contains(allowlist.user_ids, user_id)
}
