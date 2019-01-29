# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-

package require Itcl 3.4

#
# Class that handles connection between faup programs and adept
#
::itcl::class FaupConnection {
	# faup program this connection is receving data from (faup1090, faup978, etc.)
	public variable receiverType
	public variable receiverHost
	public variable receiverPort
	public variable receiverLat
	public variable receiverLon
	public variable receiverDataFormat
	public variable adsbLocalPort
	public variable adsbDataService
	public variable adsbDataProgram
	public variable faupProgramPath

	# total message from faup program
	private variable nfaupMessagesReceived
	# number of message from faup program since we last logged about is
	private variable nfaupMessagesThisPeriod
	# total messages sent to adept
	private variable nMessagesSent
	# last time we considered (re)starting faup program
	private variable lastConnectAttemptClock
	# time of the last message from faup program
	private variable lastFaupMessageClock
	# time we were last connected to data port
	private variable lastAdsbConnectedClock
	# last banner tsv_version we saw - REVISIT!
	#private variable tsvVersion ""
	# timer to start faup program connection
	private variable adsbPortConnectTimer

	private variable faupPipe
	private variable faupPid

	constructor {args} {
		configure {*}$args
	}

	destructor {
		disconnect
	}

	#
	# Connect to faup program and configure channel
	#
        method connect {} {
		unset -nocomplain adsbPortConnectTimer

		# just in case..
		disconnect

		set lastConnectAttemptClock [clock seconds]

		set args $faupProgramPath
		lappend args "--net-bo-ipaddr" $receiverHost "--net-bo-port" $receiverPort "--stdout"
		if {$receiverLat ne "" && $receiverLon ne ""} {
			lappend args "--lat" [format "%.3f" $receiverLat] "--lon" [format "%.3f" $receiverLon]
		}

		logger "Starting $this: $args"

		if {[catch {::fa_sudo::popen_as -noroot -stdout faupStdout -stderr faupStderr {*}$args} result] == 1} {
			logger "got '$result' starting $this, will try again in 5 minutes"
			#schedule_adsb_connect_attempt 300
			return
		}

		if {$result == 0} {
			logger "could not start $this: sudo refused to start the command, will try again in 5 minutes"
			#schedule_adsb_connect_attempt 300
			return
		}


		logger "Started $this (pid $result) to connect to $adsbDataProgram"
		fconfigure $faupStdout -buffering line -blocking 0 -translation lf
		fileevent $faupStdout readable [list $this data_available]

		log_subprocess_output "${this}($result)" $faupStderr

		set faupPipe $faupStdout
		set faupPid $result

		# pretend we saw a message so we don't repeatedly restart
		set lastFaupMessageClock [clock seconds]

        }

	#
	# clean up faup pipe, don't schedule a reconnect
	#
	method disconnect {} {
		if {![info exists faupPipe]} {
                        # nothing to do.
                        return
                }

                # record when we were last connected
                set lastAdsbConnectedClock [clock seconds]
                catch {kill HUP $faupPid}
                catch {close $faupPipe}

                catch {
                        lassign [timed_waitpid 15000 $faupPid] deadpid why code
                        if {$code ne "0"} {
                                logger "$this exited with $why $code"
                        } else {
                                logger "$this exited normally"
                        }
                }

                unset faupPipe
                unset faupPid
	}

	#
	# filevent callback routine when data available on socket
	#
	method data_available {} {
		# if eof, cleanly close the faup socket and reconnect...
		if {[eof $faupPipe]} {
			logger "lost connection to $adsbDataProgram via $this"
			# todo: implement restart_faup1090
			disconnect
			return
		}

		# try to read, if that fails, disconnect and reconnect...
		if {[catch {set size [gets $faupPipe line]} catchResult] == 1} {
			logger "got '$catchResult' reading from $this"
			#todo: implement restart_faup1090
			disconnect
			return
		}

		# sometimes you can get a notice of data available and not get any data.
		# it happens.  nothing to do? return.
		if {$size < 0} {
			return
		}

		incr nfaupMessagesReceived
		incr nfaupMessagesThisPeriod
		if {$nfaupMessagesReceived  == 1} {
			log_locally "piaware received a message from $adsbDataProgram!"
		}

		# TODO : PROCESS 1090 VS 978 MESSAGE APPROPRIATELY AND SEND TO ADEPT/PIREHOSE
		puts $line

		set lastFaupMessageClock [clock seconds]
	}
}
