import conversation
import gleam/http/response
import gleam/list
import hytapi/sql
import lustre/attribute as attr
import lustre/element
import lustre/element/html

pub fn home(servers: List(sql.Server)) {
  html.main([], [
    html.h3([], [html.text("servers")]),
    html.ul(
      [],
      list.map(servers, fn(server) {
        html.li([], [html.text(server.hostname <> " " <> server.key)])
      }),
    ),
    html.a([attr.href("/v1/new")], [html.text("create a new server")]),
  ])
}

pub fn layout(children: List(element.Element(a))) -> element.Element(a) {
  html.html([attr.lang("en")], [
    html.head([], [
      html.style(
        [],
        "body { background: #111; color: #eee; font-family: 'monospace'; }",
      ),
    ]),
    html.body([], children),
  ])
}

pub fn render(
  page: element.Element(a),
) -> response.Response(conversation.ResponseBody) {
  response.new(200)
  |> response.set_header("Content-Type", "text/html")
  |> response.set_body(conversation.Text(element.to_document_string(page)))
}
