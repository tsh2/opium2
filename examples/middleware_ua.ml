open Core.Std
open Async.Std
open Opium.Std
(* don't open cohttp and opium since they both define
   request/response modules*)

let is_substring ~substring s =
  Option.is_some @@ String.substr_index s ~pattern:substring

let reject_ua ~f =
  let filter handler req =
    match Cohttp.Header.get (Request.headers req) "user-agent" with
    | Some ua when f ua ->
      Log.Global.info "Rejecting %s" ua;
      `String ("Please upgrade your browser") |> respond'
    | _ -> handler req in
  Rock.Middleware.create ~filter ~name:(Info.of_string "reject_ua")

let _ = App.empty
        |> get "/" (fun req -> `String ("Hello World") |> respond')
        |> middleware @@ reject_ua ~f:(is_substring ~substring:"MSIE")
        |> App.cmd_name "Reject UA"
        |> App.command
        |> Command.run

