# -*- tcl -*-
#
# _common.tcl
#
# (c) 2001 Andreas Kupries <andreas_kupries@sourceforge.net>
# (c) 2002 Andreas Kupries <andreas_kupries@sourceforge.net>

################################################################
# The code here contains general definitions for API functions and
# state information. They are used by several formatters to simplify
# their own code.

global    state
array set state {}

proc fmt_initialize {} {
    global    state
    unset     state

    set state(pass)   unknown ; # Not relevant before a pass
    set state(begun)  unknown ; # is active
    set state(mdesc)  {}      ; # Text, module desciption
    #set state(tdesc) {}      ; # Text, title of manpage
    set state(copyright) {}   ; # Text, copyright assignment (list)
    return
}

proc fmt_shutdown    {}     {return}
proc fmt_numpasses   {}     {return 2}
proc fmt_postprocess {text} {return $text}
proc fmt_plain_text  {text} {return $text}

proc fmt_setup {n} {
    # Called to setup a pass through the input.

    global state
    set    state(pass)  $n  ; # We are in pass 'n' through the text.
    set    state(begun) 0   ; # No manpage_begin yet

    SetPassProcs $n
    return
}

################################################################
# Functions made available to the formatter to access the common
# state managed here.

proc c_inpass {} {global state ; return $state(pass)}

proc c_begin {} {global state ; set     state(begun) 1 ; return}
proc c_begun {} {global state ; return $state(begun)}

proc c_get_module {}     {global state ; return $state(mdesc)}
proc c_set_module {text} {global state ; set     state(mdesc) $text ; return}

proc c_set_title {text} {global state ; set state(tdesc) $text ; return}
proc c_get_title {} {
    global state
    if {![info exists state(tdesc)]} {
	return $state(mdesc)
    }
    return $state(tdesc)
}

proc c_set_copyright {text} {global state ; lappend state(copyright) $text ; return}
proc c_get_copyright {}     {
    global state

    set cc $state(copyright)
    if {$cc == {}} {set cc [dt_copyright]}
    if {$cc == {}} {return {}}

    return "Copyright (c) [join $cc "\nCopyright (c) "]"
}

proc c_provenance {} {
    return "Generated from file '[dt_file]' by tcllib/doctools with format '[dt_format]'"
}

################################################################
# Manage pass-dependent procedure definitions.

global PassProcs

# pass $passNo procName procArgs { body  } --
#	Specifies procedure definition for pass $n.
#
proc c_pass {pass proc arguments body} {
    global  PassProcs
    lappend PassProcs($pass) $proc $arguments $body
}
proc SetPassProcs {pass} {
    global PassProcs
    foreach {proc args body} $PassProcs($pass) {
	proc $proc $args $body
    }
}


################################################################
# Manage a set of buffers to hold information between passes.
# Each buffer holds a list of lines.

global Buffers

# holdBuffers buffer ? buffer ...? --
#	Declare a list of hold buffers,
#	to collect data in one pass and output it later.
#
proc c_holdBuffers {args} {
    global Buffers
    foreach arg $args {
	set Buffers($arg) [list]
    }
}

proc c_holdRemove {args} {
    global Buffers
    foreach arg $args {
	catch {unset Buffers($arg)}
    }
    return
}

# hold buffer text --
#	Append text to named buffer
#
proc c_hold {buffer entry} {
    global  Buffers
    lappend Buffers($buffer) $entry

    #puts "$buffer -- $entry"
    return
}

proc c_holding {buffer} {
    global  Buffers
    set l 0
    catch {set l [llength $Buffers($buffer)]}
    return $l
}

# held buffer --
#	Returns current contents of named buffer and empty the buffer.
#
proc c_held {buffer} {
    global Buffers
    set content [join $Buffers($buffer) "\n"]
    set Buffers($buffer) [list]
    return $content
}

######################################################################
# Nested counter

global counters cnt
set    counters [list]
set    cnt 0

proc c_cnext {} {global cnt ; incr cnt}
proc c_cinit {} {
    global counters cnt
    set counters [linsert $counters 0 $cnt]
    set cnt      0
    return
}
proc c_creset {} {
    global counters cnt
    set cnt      [lindex $counters 0]
    set counters [lrange $counters 1 end]
    return
}


######################################################################
# Utilities.
#

proc NOP {args} { }		;# do nothing
proc NYI {{message {}}} {
    return -code error [append message " Not Yet Implemented"]
}

######################################################################
# Cross-reference tracking (for a single file).
#
global SectionNames	;# array mapping 'section name' to 'reference id'

# sectionId --
#	Format section name as an XML ID.
#
proc c_sectionId {name} {
    regsub -all {[^[:alnum:]]} $name {} name
    return [string tolower $name]
}

# possibleReference text gi --
#	Check if $text is a potential cross-reference;
#	if so, format as a reference;
#	otherwise format as a $gi element.
#
proc c_possibleReference {text gi} {
    global SectionNames
    if {[info exists SectionNames($text)]} {
    	return "[startTag ref refid $SectionNames($text)]$text[endTag ref]"
    } else {
    	return [wrap $text $gi]
    }
}

######################################################################
# Conversion specification.
#
# Two-pass processing.  The first pass collects text for the
# SYNOPSIS, SEE ALSO, and KEYWORDS sections, and the second pass
# produces output.
#

c_holdBuffers synopsis see_also keywords precomments

################################################################
