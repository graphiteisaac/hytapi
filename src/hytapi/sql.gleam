import gleam/dynamic/decode
import gleam/int
import gleam/javascript/array
import gleam/javascript/promise
import gleam/list
import gleam/result
import gleam/string
import plinth/cloudflare/d1

pub type User {
  User(id: Int, discord_id: String, created_at: Int)
}

fn user_decoder() -> decode.Decoder(User) {
  use id <- decode.field("id", decode.int)
  use discord_id <- decode.field("discord_id", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  decode.success(User(id:, discord_id:, created_at:))
}

pub fn discord_id_user(
  db: d1.Database,
  discord_id: String,
) -> promise.Promise(Result(User, String)) {
  use res <- promise.try_await(
    d1.prepare(
      db,
      "SELECT id, discord_id, created_at FROM users WHERE discord_id = ?",
    )
    |> d1.bind([discord_id])
    |> d1.first,
  )

  promise.resolve(
    decode.run(res, user_decoder())
    |> result.map_error(fn(errors) {
      "Could not retrieve a user from the database: " <> string.inspect(errors)
    }),
  )
}

pub fn create_user(
  db: d1.Database,
  discord_id: String,
) -> promise.Promise(Result(User, String)) {
  use res <- promise.try_await(
    d1.prepare(
      db,
      "INSERT INTO users (discord_id, created_at) VALUES (?, unixepoch()) RETURNING id, discord_id, created_at",
    )
    |> d1.bind([discord_id])
    |> d1.first,
  )

  promise.resolve(
    decode.run(res, user_decoder())
    |> result.map_error(fn(errors) {
      "Could not retrieve a user from the database: " <> string.inspect(errors)
    }),
  )
}

pub fn get_or_create_user(
  db: d1.Database,
  discord_id: String,
) -> promise.Promise(Result(User, String)) {
  use user_result <- promise.await(discord_id_user(db, discord_id))

  case user_result {
    Ok(user) -> promise.resolve(Ok(user))
    Error(_) -> create_user(db, discord_id)
  }
}

pub type Server {
  Server(
    id: Int,
    hostname: String,
    key: String,
    players_online: Int,
    created_at: Int,
    updated_at: Int,
  )
}

fn server_decoder() -> decode.Decoder(Server) {
  use id <- decode.field("id", decode.int)
  use hostname <- decode.field("hostname", decode.string)
  use key <- decode.field("keystring", decode.string)
  use players_online <- decode.field("players_online", decode.int)
  use created_at <- decode.field("created_at", decode.int)
  use updated_at <- decode.field("updated_at", decode.int)

  decode.success(Server(
    id:,
    hostname:,
    key:,
    players_online:,
    created_at:,
    updated_at:,
  ))
}

pub fn get_user_servers(
  db: d1.Database,
  user_id: Int,
) -> promise.Promise(Result(List(Server), String)) {
  use res <- promise.try_await(
    d1.prepare(
      db,
      "SELECT servers.id, servers.hostname, servers.keystring, servers.players_online, servers.created_at, servers.updated_at FROM servers 
      INNER JOIN server_operators so ON servers.id = so.server_id
      WHERE so.user_id = ?",
    )
    |> d1.bind([int.to_string(user_id)])
    |> d1.run,
  )

  case res {
    d1.RunResult(success: True, results:, ..) -> {
      results
      |> array.to_list
      |> list.map(fn(server) {
        decode.run(server, server_decoder())
        |> result.replace_error("could not decode servers")
      })
      |> result.all
      |> promise.resolve()
    }
    _ -> promise.resolve(Error("could not retrieve servers for user"))
  }
}

pub fn create_new_server(
  db: d1.Database,
) -> promise.Promise(Result(Int, String)) {
  use res <- promise.try_await(
    d1.prepare(
      db,
      "INSERT INTO servers (hostname, keystring, players_online, created_at, updated_at) VALUES ('', hex(randomblob(16)), 0, unixepoch(), unixepoch()) RETURNING id",
    )
    |> d1.first,
  )

  case decode.run(res, decode.int) {
    Ok(server_id) -> promise.resolve(Ok(server_id))
    Error(_) -> promise.resolve(Error("could not create server"))
  }
}

pub fn add_server_operator(
  db: d1.Database,
  server_id: Int,
  user_id: Int,
) -> promise.Promise(Nil) {
  use _ <- promise.await(
    d1.prepare(
      db,
      "INSERT INTO server_operators (server_id, user_id) VALUES (?, ?)",
    )
    |> d1.bind([int.to_string(server_id), int.to_string(user_id)])
    |> d1.run,
  )

  promise.resolve(Nil)
}
