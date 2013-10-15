open Core.Std
open Async.Std
open Cow

module C = Cohttp
module Co = Cohttp_async

let tap x ~f = (ignore (f x); x)

(* for now we will use PCRE's *)
module Route = struct
  type t = Pcre.regexp

  let get_named_matches ?rex ?pat s =
    let rex = match rex, pat with
      | Some _, Some _ -> invalid_arg "cannot provide pat and rex"
      | None, None -> invalid_arg "must provide at least ?pat or ?rex"
      | Some r, None -> r
      | None, Some p -> Pcre.regexp p
    in
    let all_names = Pcre.names rex in
    let subs = Pcre.exec ~rex s in
    all_names |> Array.to_list |> List.map ~f:(fun name ->
        (name, Pcre.get_named_substring rex name subs))

  let pcre_of_route route =
    let compile_to_pcre s =
      Pcre.substitute ~pat:":\\w+" ~subst:(fun s ->
          Printf.sprintf "(?<%s>[^/]+)" 
            (String.chop_prefix_exn s ~prefix:":")) s
    in compile_to_pcre (route ^ "$")

  let create path = path |> pcre_of_route |> Pcre.regexp

  let match_url t s = 
    let rex = t in
    if not (Pcre.pmatch ~rex s) then None
    else Some (get_named_matches ~rex s)
end

module Request = struct
  type t = {
    raw : Co.Request.t;
    params : (string * string) list;
  }
  let raw {raw;_} = raw
  let param {params;_} p = List.Assoc.find_exn params p
end

module Response = struct
  type t = Co.Server.response
  type special = [
    | `Json of Json.t
    | `Html of Html.t
    | `Xml of Xml.t ]

  let content_type ct = Cohttp.Header.init_with "Content-Type" ct

  let json_header = content_type "application/json"
  let xml_header = content_type "application/xml"
  let html_header = content_type "text/html"

  let respond ?headers ?(code=`OK) = function
    | `String s -> Co.Server.respond_with_string ?headers ~code s
    | `Pipe p -> Co.Server.respond_with_pipe ?headers ~code p
    | `Json s ->
      Co.Server.respond_with_string ~headers:json_header (Json.to_string s)
    | `Html s ->
      Co.Server.respond_with_string ~headers:html_header (Html.to_string s)
    | `Xml s ->
      Co.Server.respond_with_string ~headers:xml_header (Xml.to_string s)
end

module Action = struct
  type t = Request.t -> Response.t
end

module Local_map = struct
  type t = {
    prefix: string;
    local_path: string; }

  let legal_path {prefix;local_path} requested = 
    let open Option in
    (String.chop_prefix requested ~prefix >>= fun p ->
     let requested_path = Filename.concat local_path p
     in Option.some_if 
       (String.is_prefix requested_path ~prefix:local_path) requested_path)

  let public_serve t ~requested =
    match legal_path t requested with (* serve the file if it exists legally *)
    | None -> return None
    | Some legal_path ->
      Sys.is_file legal_path >>= function
      | `Yes -> (Co.Server.respond_with_file legal_path) >>| Option.some
      | _ -> return None
end

module Method_bin = struct
  type 'a t = 'a Queue.t array

  let create () = Array.init 7 ~f:(fun _ -> Queue.create ())

  let int_of_meth = function
    | `GET     -> 0
    | `POST    -> 1
    | `PUT     -> 2
    | `DELETE  -> 3
    | `HEAD    -> 4
    | `PATCH   -> 5
    | `OPTIONS -> 6

  let add t meth value = Queue.enqueue t.(int_of_meth meth) value

  let get t meth = t.(int_of_meth meth)
end

module App = struct
  type 'action endpoint = {
    meth: C.Code.meth;
    route: Route.t;
    action: 'action;
  }

  type t = {
    before_filters : (Co.Request.t -> Co.Request.t Deferred.t) Queue.t;
    routes : (Request.t -> Response.t Deferred.t) endpoint Method_bin.t;
    after_filters : (Response.t -> Response.t Deferred.t) Queue.t;
    not_found : (Request.t -> Response.t Deferred.t);
    public_dir : Local_map.t option;
  }

  let local_path = Fn.compose Uri.path C.Request.uri

  let register app ~meth ~route ~action =
    Method_bin.add app.routes meth {meth; route; action}

  let not_found not_found app = { app with not_found }

  let app () = 
    let not_found req = 
      let path = req |> Request.raw |> local_path in
      Co.Server.respond_with_string ~code:`Not_found ("Not found: " ^ path)
    in
    let public_dir =
      let open Local_map in
      Some { prefix="/public"; local_path="./public" } in
    { before_filters=Queue.create ();
      routes=Method_bin.create ();
      after_filters=Queue.create ();
      public_dir; not_found }

  let public_path root requested =
    let asked_path = Filename.concat root requested in
    Option.some_if (String.is_prefix asked_path ~prefix:root) asked_path

  let matching_endpoint endpoints req uri =
    let endpoints = Method_bin.get endpoints (C.Request.meth req) in
    endpoints |> Queue.find_map ~f:(fun ep -> 
        uri |> Route.match_url ep.route |> Option.map ~f:(fun p -> (ep, p)))

  let server ?(port=3000) app =
    Co.Server.create ~on_handler_error:`Raise (Tcp.on_port port)
      (fun ~body sock req -> 
         let uri        = local_path req in
         let endpoint   = matching_endpoint app.routes req uri in
         match endpoint with
         | Some ({route;action;_}, params) ->
           action Request.({ raw=req; params })
         | None -> 
           let resp = 
             match app.public_dir with
             | Some pd -> Local_map.public_serve pd ~requested:uri
             | None -> return None
           in resp >>= function
           | None -> app.not_found @@ Request.({raw=req; params=[]})
           | Some s -> return s
      ) >>= fun _ -> Deferred.never ()
end

module Std = struct
  module Response = Response
  module Request = Request
  module App = App

  let get route action =
    App.register ~meth:`GET ~route:(Route.create route) ~action
  let post route action =
    App.register ~meth:`POST ~route:(Route.create route) ~action
  let delete route action =
    App.register ~meth:`DELETE ~route:(Route.create route) ~action
  let put route action =
    App.register ~meth:`PUT ~route:(Route.create route) ~action

  let not_found = App.not_found
  let app = App.app

  let before action = ()
  let after action = ()

  let start endpoints = 
    let app = App.app () in
    endpoints |> List.iter ~f:(fun e -> e app);
    app |> App.server |> ignore;
    Scheduler.go ()
end
