###
# Return data from an SCGI process
###
::clay::define ::httpd::content.scgi {
  superclass ::httpd::content.proxy

  method scgi_info {} {
    ###
    # This method should check if a process is launched
    # or launch it if needed, and return a list of
    # HOST PORT SCRIPT_NAME
    ###
    # return {localhost 8016 /some/path}
    error unimplemented
  }

  method proxy_channel {} {
    set sockinfo [my scgi_info]
    if {$sockinfo eq {}} {
      my error 404 {Not Found}
      tailcall my DoOutput
    }
    lassign $sockinfo scgihost scgiport scgiscript
    my clay set  SCRIPT_NAME $scgiscript
    if {![string is integer $scgiport]} {
      my error 404 {Not Found}
      tailcall my DoOutput
    }
    return [::socket $scgihost $scgiport]
  }

  method ProxyRequest {chana chanb} {
    chan event $chanb writable {}
    my log ProxyRequest {}
    chan configure $chana -translation binary -blocking 0 -buffering full -buffersize 4096
    chan configure $chanb -translation binary -blocking 0 -buffering full -buffersize 4096
    set info [dict create CONTENT_LENGTH 0 SCGI 1.0 SCRIPT_NAME [my clay get SCRIPT_NAME]]
    foreach {f v} [my clay dump] {
      dict set info $f $v
    }
    set length [dict get $info CONTENT_LENGTH]
    set block {}
    foreach {f v} $info {
      append block [string toupper $f] \x00 $v \x00
    }
    chan puts -nonewline $chanb "[string length $block]:$block,"
    # Light off another coroutine
    #set cmd [list coroutine [my CoroName] {*}[namespace code [list my ProxyReply $chanb $chana]]]
    if {$length} {
      chan configure $chana -translation binary -blocking 0 -buffering full -buffersize 4096
      chan configure $chanb -translation binary -blocking 0 -buffering full -buffersize 4096
      ###
      # Send any POST/PUT/etc content
      ###
      chan copy $chana $chanb -size $length -command [info coroutine]
    } else {
      chan flush $chanb
      chan event $chanb readable [info coroutine]
    }
    yield
  }

  method ProxyReply {chana chanb args} {
    my log ProxyReply [list args $args]
    chan event $chana readable {}
    set replyhead [my HttpHeaders $chana]
    set replydat  [my MimeParse $replyhead]
    if {![dict exists $replydat Content-Length]} {
      set length 0
    } else {
      set length [dict get $replydat Content-Length]
    }
    ###
    # Convert the Status: header from the CGI process to
    # a standard service reply line from a web server, but
    # otherwise spit out the rest of the headers verbatim
    ###
    set replybuffer "HTTP/1.0 [dict get $replydat Status]\n"
    append replybuffer $replyhead
    chan configure $chanb -translation {auto crlf} -blocking 0 -buffering full -buffersize 4096
    chan puts $chanb $replybuffer
    my log SendReply [list length $length]
    if {$length} {
      ###
      # Output the body
      ###
      chan configure $chana -translation binary -blocking 0 -buffering full -buffersize 4096
      chan configure $chanb -translation binary -blocking 0 -buffering full -buffersize 4096
      chan copy $chana $chanb -size $length -command [namespace code [list my TransferComplete $chana $chanb]]
    } else {
      my TransferComplete $chan $chanb
    }
  }
}

::clay::define ::httpd::reply.scgi {
  superclass ::httpd::reply

  method EncodeStatus {status} {
    return "Status: $status"
  }
}

###
# Act as an  SCGI Server
###
::clay::define ::httpd::server.scgi {
  superclass ::httpd::server

  clay set socket/ buffersize   32768
  clay set socket/ blocking     0
  clay set socket/ translation  {binary binary}

  clay set reply_class ::httpd::reply.scgi

  method debug args {
    puts $args
  }

  method Connect {uuid sock ip} {
    yield [info coroutine]
    chan event $sock readable {}
    chan configure $sock \
        -blocking 1 \
        -translation {binary binary} \
        -buffersize 4096 \
        -buffering none
    my counter url_hit
    try {
      # Read the SCGI request on byte at a time until we reach a ":"
      dict set query REQUEST_URI /
      dict set query REMOTE_ADDR     $ip
      set size {}
      while 1 {
        set char [::coroutine::util::read $sock 1]
        if {[chan eof $sock]} {
          catch {close $sock}
          return
        }
        if {$char eq ":"} break
        append size $char
      }
      # With length in hand, read the netstring encoded headers
      set inbuffer [::coroutine::util::read $sock [expr {$size+1}]]
      chan configure $sock -blocking 0 -buffersize 4096 -buffering full
      foreach {f v} [lrange [split [string range $inbuffer 0 end-1] \0] 0 end-1] {
        dict set query $f $v
        if {$f in {CONTENT_LENGTH CONTENT_TYPE}} {
          dict set query http $f $v
        } elseif {[string range $f 0 4] eq "HTTP_"} {
          dict set query http [string range $f 5 end] $v
        }
      }
      if {![dict exists $query REQUEST_PATH]} {
        set uri [dict get $query REQUEST_URI]
        set uriinfo [::uri::split $uri]
        dict set query REQUEST_PATH    [dict get $uriinfo path]
      }
      set reply [my dispatch $query]
    } on error {err errdat} {
      my debug [list uri: [dict getnull $query REQUEST_URI] ip: $ip error: $err errorinfo: [dict get $errdat -errorinfo]]
      my log BadRequest $uuid [list ip: $ip error: $err errorinfo: [dict get $errdat -errorinfo]]
      catch {chan puts $sock "HTTP/1.0 400 Bad Request (The data is invalid)"}
      catch {chan event readable $sock {}}
      catch {chan event writeable $sock {}}
      catch {chan close $sock}
      return
    }
    if {[dict size $reply]==0} {
      my log BadLocation $uuid $query
      dict set query HTTP_STATUS 404
      dict set query template notfound
      dict set query mixin reply ::httpd::content.template
    }
    try {
      if {[dict exists $reply class]} {
        set class [dict get $reply class]
      } else {
        set class [my clay get reply_class]
      }
      set pageobj [$class create ::httpd::object::$uuid [self]]
      if {[dict exists $reply mixin]} {
        set mixinmap [dict get $reply mixin]
      } else {
        set mixinmap {}
      }
      foreach item [dict keys $reply MIXIN_*] {
        set slot [string range $reply 6 end]
        dict set mixinmap [string tolower $slot] [dict get $reply $item]
      }
      $pageobj clay mixinmap {*}$mixinmap
      if {[dict exists $reply delegate]} {
        $pageobj clay delegate {*}[dict get $reply delegate]
      }
    } on error {err errdat} {
      my debug [list ip: $ip error: $err errorinfo: [dict get $errdat -errorinfo]]
      my log BadRequest $uuid [list ip: $ip error: $err errorinfo: [dict get $errdat -errorinfo]]
      catch {$pageobj destroy}
      catch {chan event readable $sock {}}
      catch {chan event writeable $sock {}}
      catch {chan close $sock}
      return
    }
    try {
      $pageobj dispatch $sock $reply
    } on error {err errdat} {
      my debug [list ip: $ip error: $err errorinfo: [dict get $errdat -errorinfo]]
      my log BadRequest $uuid [list ip: $ip error: $err errorinfo: [dict get $errdat -errorinfo]]
      catch {$pageobj destroy}
      catch {chan close $sock}
      return
    }
  }
}
