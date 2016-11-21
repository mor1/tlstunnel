open Lwt.Infix

let http_src = Logs.Src.create "tlstunnel/http" ~doc:"TLS Tunnel: HTTP"
module Http_log = (val Logs.src_log http_src : Logs.LOG)

let https_src = Logs.Src.create "tlstunnel/https" ~doc:"TLS Tunnel: HTTPS"
module Https_log = (val Logs.src_log https_src : Logs.LOG)

module Main
    (Clock: V1.CLOCK)
    (Keys: V1_LWT.KV_RO)
    (Stack: V1_LWT.STACKV4)
= struct

  module Logs_reporter = Mirage_logs.Make(Clock)

  module TCP = Stack.TCPV4
  module TLS = Tls_mirage.Make(TCP)
  module X509 = Tls_mirage.X509(Keys)(Clock)

  let infos peer port s = Https_log.info
      (fun f -> f "HTTPS [%s:%d] %s" (Ipaddr.V4.to_string peer) port s)
  let errors peer port s = Https_log.err
      (fun f -> f "HTTPS [%s:%d] error: %s" (Ipaddr.V4.to_string peer) port s)

  let info peer port s = Http_log.info
      (fun f -> f "HTTP [%s:%d] %s" (Ipaddr.V4.to_string peer) port s)
  let error peer port s = Http_log.err
      (fun f -> f "HTTP [%s:%d] error: %s" (Ipaddr.V4.to_string peer) port s)

  type rd_wr_result = Stop | Continue

  let rec read_write info error plain tls =
    info "read_write" ;

    let inbound =
      TLS.read tls
      >>= (function
          | `Ok buf -> (
              let buflen = Cstruct.len buf in
              info ("read "^(string_of_int buflen)^" bytes\nbuf:\n"
                    ^(Cstruct.to_string buf)) ;
              if      buflen = 0 then Lwt.return Continue
              else if buflen < 0 then Lwt.return Stop
              else (* buflen > 0 *) (
                TCP.write plain buf
                >>= function
                | `Ok () ->
                  info ("wrote "^(string_of_int buflen)^" bytes") ;
                  Lwt.return Continue
                | `Error e -> error (TCP.error_message e) ; Lwt.return Stop
                | `Eof -> info "write eof." ; Lwt.return Stop
              )
            )
          | `Error e -> error (TLS.error_message e) ; Lwt.return Stop
          | `Eof -> info "read eof." ; Lwt.return Stop
        )
    in

    let outbound =
      TCP.read plain
      >>= (function
          | `Ok buf -> (
              let buflen = Cstruct.len buf in
              info ("read "^(string_of_int buflen)^" bytes\nbuf:\n"
                    ^(Cstruct.to_string buf)) ;
              if      buflen = 0 then Lwt.return Continue
              else if buflen < 0 then Lwt.return Stop
              else (* buflen > 0 *) (
                TLS.write tls buf
                >>= function
                | `Ok () ->
                  info ("wrote "^(string_of_int buflen)^" bytes") ;
                  Lwt.return Continue
                | `Error e -> error (TLS.error_message e) ; Lwt.return Stop
                | `Eof -> info "write eof." ; Lwt.return Stop
              )
            )
          | `Error e -> error (TCP.error_message e) ; Lwt.return Stop
          | `Eof -> info "read eof." ; Lwt.return Stop
        )
    in

    Lwt.catch (fun () -> inbound <?> outbound)
      (function
        | exn ->
          info ("tls_rdwr: fail: "^(Printexc.to_string exn)) ;
          Lwt.return Stop
      )
    >>= function
    | Stop -> Lwt.return_unit
    | Continue -> read_write info error plain tls

  let tls_info t =
    let v, c =
      match TLS.epoch t with
      | `Ok data -> (data.Tls.Core.protocol_version, data.Tls.Core.ciphersuite)
      | `Error -> assert false
    in
    let version = Sexplib.Sexp.to_string_hum (Tls.Core.sexp_of_tls_version v)
    and cipher =
      Sexplib.Sexp.to_string_hum (Tls.Ciphersuite.sexp_of_ciphersuite c)
    in
    version ^ ", " ^ cipher

  let accept_tls config to_plain flow f =
    let peer, port = TCP.get_dest flow in
    let infos s = infos peer port s in
    let errors s = errors peer port s in

    TLS.server_of_flow config flow
    >>= function
    | `Ok tls ->
      infos ("connect: "^(tls_info tls)) ;
      to_plain ()
      >>= fun plain ->
      read_write infos errors plain tls
      >>= fun () ->
      TLS.close tls
    | `Error e -> errors ("error: "^(TLS.error_message e)) ; TCP.close flow
    | `Eof -> infos "eof." ; TCP.close flow

  let tls_init keys =
    X509.certificate keys `Default

    >>= fun cert ->
    let config = Tls.Config.server ~certificates:(`Single cert) () in
    Lwt.return config

  let start _clock keys stack _entropy =
    Logs.(set_level (Some Info));
    Logs_reporter.(create () |> run) @@ fun () ->

    let http_ip = Key_gen.http_ip () in
    let http_port = Key_gen.http_port () in
    Http_log.info (fun f -> f "forwarding to [%s]:%d/TCP" http_ip http_port) ;

    let to_plain () =
      let http_ipv4 =
        Ipaddr.V4.of_string http_ip |> function
        | None -> failwith ("bad HTTP target IP: "^http_ip)
        | Some ip -> ip
      in

      TCP.create_connection (Stack.tcpv4 stack) (http_ipv4, http_port)
      >>= (function
          | `Error err -> failwith ("outbound connection! ["^http_ip^"]:"
                                    ^(string_of_int http_port))
          | `Ok flow -> Lwt.return flow
        )
    in

    tls_init keys

    >>= fun config ->
    let https flow = accept_tls config to_plain flow read_write in
    let https_ip = "0.0.0.0" in (* Key_gen.https_ip () in *)
    let https_port = Key_gen.https_port () in
    Stack.listen_tcpv4 stack ~port:https_port https ;
    Https_log.info (fun f -> f "listening on [%s]:%d/TCP" https_ip https_port) ;

    Stack.listen stack

end
