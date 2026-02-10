import conversation
import gleam/http/response
import gleam/int
import gleam/list
import hytapi/sql
import lustre/attribute as attr
import lustre/element
import lustre/element/html

// PAGES

pub fn home(servers: List(sql.Server)) {
  html.main([], [
    html.h3([], [html.text("your servers")]),
    html.table([attr.class("servers")], [
      html.thead([], [
        html.tr([], [
          html.th([], [html.text("label")]),
          html.th([], [html.text("hostname")]),
          html.th([], [html.text("players")]),
          html.th([], [html.text("key")]),
          html.th([], []),
        ]),
      ]),
      html.tbody(
        [],
        list.map(servers, fn(server) {
          html.tr([], [
            html.td([], [html.text(server.label)]),
            html.td([], [
              html.text(case server.hostname {
                "" -> "not yet pinged"
                hostname -> hostname
              }),
            ]),
            html.td([], [html.text(int.to_string(server.players_online))]),
            html.td([], [
              html.code([attr.class("key")], [html.text(server.key)]),
            ]),
            html.td([], [
              html.a(
                [
                  attr.class("delete"),
                  attr.href("/delete/" <> int.to_string(server.id)),
                ],
                [html.text("delete")],
              ),
            ]),
          ])
        }),
      ),
    ]),
    html.a([attr.href("/new"), attr.class("btn btn-primary")], [
      html.text("create a new server"),
    ]),
    html.section([], [
      html.h3([], [html.text("documentation")]),
      html.h5([], [html.text("version 0 (alpha)")]),
      html.p([], [
        html.text(
          "GET OR POST /v0/set/{key}/{count} - set a server status using a key. no body, uses request origin IP to set hostname.",
        ),
      ]),
      html.p([], [
        html.text("GET /v0/players/{hostname} - get an IP address playercount"),
      ]),
      html.p([], [
        html.text(
          "when logged in, create a server and use the created key in the plugin.",
        ),
      ]),
    ]),
  ])
}

pub fn create_server() {
  html.main([], [
    html.h3([], [html.text("create a new server")]),
    html.form([attr.method("POST"), attr.action("#")], [
      html.p([attr.class("notice")], [
        html.text("are you sure you want to create a new server?"),
      ]),

      html.div([attr.class("form-section")], [
        html.label([attr.for("label")], [html.text("server label")]),
        html.input([
          attr.id("label"),
          attr.name("label"),
          attr.type_("text"),
          attr.required(True),
        ]),
      ]),

      html.footer([attr.class("buttons")], [
        html.a([attr.href("/"), attr.class("btn")], [
          html.text("i've changed my mind"),
        ]),
        html.button([attr.type_("submit"), attr.class("btn btn-primary")], [
          html.text("yes, i am sure"),
        ]),
      ]),
    ]),
  ])
}

pub fn delete_server(server: sql.Server) {
  html.main([], [
    html.h3([], [html.text("delete server #" <> int.to_string(server.id))]),
    html.form([attr.method("POST"), attr.action("#")], [
      html.p([attr.class("notice")], [
        html.text("are you sure you want to delete this server?"),
      ]),

      html.table([attr.class("servers")], [
        html.thead([], [
          html.tr([], [
            html.th([], [html.text("id")]),
            html.th([], [html.text("label")]),
            html.th([], [html.text("hostname")]),
            html.th([], [html.text("players")]),
            html.th([], [html.text("key")]),
          ]),
        ]),
        html.tbody([], [
          html.tr([], [
            html.td([], [html.text("#" <> int.to_string(server.id))]),
            html.td([], [html.text(server.label)]),
            html.td([], [
              html.text(case server.hostname {
                "" -> "not yet pinged"
                hostname -> hostname
              }),
            ]),
            html.td([], [html.text(int.to_string(server.players_online))]),
            html.td([], [
              html.code([attr.class("key")], [html.text(server.key)]),
            ]),
          ]),
        ]),
      ]),

      html.footer([attr.class("buttons")], [
        html.a([attr.href("/"), attr.class("btn")], [
          html.text("i've changed my mind"),
        ]),
        html.button([attr.type_("submit"), attr.class("btn btn-primary")], [
          html.text("yes, i am sure"),
        ]),
      ]),
    ]),
  ])
}

pub fn login() {
  html.main([], [
    html.h3([], [html.text("login")]),
    html.section([], [
      html.a([attr.class("btn"), attr.href("/auth/discord")], [
        html.text("login with Discord"),
      ]),
    ]),
  ])
}

// LAYOUT

const css = "
:root {
  --brand: #5dabea;
}

body {
  background: #111; 
  color: #eee;
  font-family: 'monospace';
  margin: 0; 
  padding: 1rem;
}

a {
  color: #fff;
  text-decoration: underline;
}

a:hover {
  color: var(--brand);
}

.btn {
  display: inline-flex; 
  align-items: center;
  border: none; 
  border-radius: .3rem; 
  padding: .6rem 1rem; 
  font-weight: bold; 
  cursor: pointer;
  text-decoration: none;
  background: #222;
  color: #8d8d8d;
  font-size: 1rem;
}

.btn-primary {
  background-color: var(--brand);
  color: #000 !important;
}

.servers {
  border-collapse: collapse;  
  border: 1px dashed #333; 
  margin-bottom: 1.2rem;
}

.servers td, .servers th {
  border: 1px dashed #333; 
  padding: .6rem 1rem;
}

.servers .key {
  font-size: .85rem;
  display: flex;
  align-items: center;
}

.servers th {
  color: #8d8d8d;
  font-size: .95rem;
  text-align: left;
}

.notice {
  padding: 1rem;
  margin-bottom: 1.2rem;
  border: 1px dashed #333;
  color: #8d8d8d;
}

.buttons {
  display: flex;
  flex-wrap: wrap;
  gap: .8rem;
}

.delete {
  color: #ee2f3c !important;
  cursor: pointer;
  text-decoration: none;
  font-size: .8rem;
}

.form-section {
  margin-bottom: 1.2rem;
}

.form-section label {
  margin-bottom: .4rem;
  color: #bdbdbd;
  font-size: .8rem;
  display: block;
}

.form-section input[type=\"text\"] {
  background: #222;
  border: none;
  border-radius: .3rem;
  padding: .6rem 1.2rem;
  color: #fff;
}

.form-section input:focus {
  outline: none;
}
"

pub fn layout(children: List(element.Element(a))) -> element.Element(a) {
  html.html([attr.lang("en")], [
    html.head([], [
      html.style([], css),
    ]),
    html.body([], [
      html.h2([], [html.text("hytapi - get your hytale playercount")]),
      ..children
    ]),
  ])
}

// UTILITY

pub fn render(
  page: element.Element(a),
) -> response.Response(conversation.ResponseBody) {
  response.new(200)
  |> response.set_header("Content-Type", "text/html")
  |> response.set_body(conversation.Text(element.to_document_string(page)))
}
