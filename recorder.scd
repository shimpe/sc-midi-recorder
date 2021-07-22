(
if (MIDIClient.initialized.not) { MIDIClient.init; };
~mididevice = MIDIIn.connectAll;

~midiout = MIDIOut.newByName("CASIO USB-MIDI", "CASIO USB-MIDI MIDI 1");
~midiout.latency_(0);

~midirec = (
	\safeReg : {
		| self, name, implementation, verbose=0 |
		var symbolicname = name.asSymbol;
		if (self.respondsTo(symbolicname)) {
			("Error! Registering" + "\\" ++ symbolicname + "would overwrite a member that exists already.").postln;
		} {
			if (self.keys.includes(symbolicname)) {
				("Error! Cannot register" + "\\" ++ symbolicname + "twice.").postln;
			} {
				if (verbose != 0) {
					("Registered" + "\\" ++ symbolicname ++ ".").postln;
				};
				self[symbolicname] = implementation;
			};
		};
	};
);

// user configurable stuff
~midirec.safeReg(\verbose, true);  //set to false to disable debug code
~midirec.safeReg(\current_track, 0);
~midirec.safeReg(\start_recording_at_first_event, true);
~midirec.safeReg(\bpm, 120);
~midirec.safeReg(\number_of_bars, 4);
~midirec.safeReg(\timesig_nom, 4);
~midirec.safeReg(\timesig_denom, 4);
~midirec.safeReg(\quantization, 0); // 0 = no quantization; use 1 for quarter note

// internal stuff
~midirec.safeReg(\next_bpm, 120);
~midirec.safeReg(\midiout, {|self| ~midiout});
~midirec.safeReg(\start_time, nil);
~midirec.safeReg(\pause_recording, 0);
~midirec.safeReg(\collapsed_events, []);
~midirec.safeReg(\collapsed_deltas, []);
~midirec.safeReg(\mainwin, nil);
~midirec.safeReg(\interrupt, false);
~midirec.safeReg(\time_to_beat, {
	| self, time_since_start_recording |
	(self.bpm / 60) * time_since_start_recording;
});
~midirec.safeReg(\beat_to_time, {
	| self, beat |
	60*beat/self.bpm;
});
~midirec.safeReg(\wrapped_beat_from_time, {
	| self, time_since_start_recording |
	if (self.start_time.notNil) {
		self.time_to_beat(time_since_start_recording).debug("before mod").mod(self.timesig_nom*self.number_of_bars).debug("after mod");
	} /*else*/ {
		0;
	};
});
~midirec.safeReg(\current_beat, {
	| self |
	if (self.start_time.notNil) {
		self.time_to_beat(thisThread.seconds - self.start_time).mod(self.timesig_nom*self.number_of_bars);
	} /*else*/ {
		0;
	};
});
~midirec.safeReg(\start_recording, { |self|
	self.start_time = thisThread.seconds;
	SystemClock.sched(self.beat_to_time(self.timesig_nom*self.number_of_bars), {self.play_recorded_events; nil});
	if (self.verbose) {
		"Recording started!".postln;
	};
});
~midirec.safeReg(\midi_events, ());
~midirec.safeReg(\trackkey, { | self, trackid | ("track" ++ trackid).asSymbol;} );
~midirec.safeReg(\start_recording_if_needed, { | self |
	if (self.start_recording_at_first_event) {
		self.interrupt = false;
		self.start_recording;
		self.start_recording_at_first_event = false;
	}
});
~midirec.safeReg(\add_track_if_needed, { | self, trackid |
	var trackkey = self.trackkey(trackid);
	if (self.midi_events[trackkey].isNil) {
		self.midi_events[trackkey] = (\recorded : [], \quantized : []);
	};
});
~midirec.safeReg(\check_preconditions, { |self, trackid |
	self.start_recording_if_needed;
	self.add_track_if_needed(trackid);
});
~midirec.safeReg(\gui_update_task, { | self |
	Tdef(\guiupdate, {
		while ({true}) {
			//"gui update".postln;
			defer { self.mainwin.refresh };
			0.05.wait;
		}
	});
});

~midirec.safeReg(\stopAll, { |self|
	"stopping!".postln;
	self.interrupt = true;
	self.all_notes_off;
	self.gui_update_task.stop;
	Window.closeAll;
});

~midirec.safeReg(\show_gui, { | self |
	var row, row2, row3, row4, metronome, ui;
	self.mainwin = Window().onClose_({
        ~midirec.stopAll;
		"Closing window!".postln;
	}).front;
	row = [
		StaticText().string_("Time sig"),
		TextField().string_(self.timesig_nom).action_({
			| control |
			self.timesig_nom = control.string.asInteger;
			if (self.verbose) {
				("" + self.timesig_nom + "/" + self.timesig_denom).debug("new time signature");
			}
		}),
		StaticText().string_("/"),
		TextField().string_(self.timesig_denom).action_({
			| control |
			self.timesig_denom = control.string.asInteger;
			if (self.verbose) {
				("" + self.timesig_nom + "/" + self.timesig_denom).debug("new time signature");
			}
		}),
		StaticText().string_("Bars"),
		TextField().string_(self.number_of_bars).action_({
			| control |
			self.number_of_bars = control.string.asInteger;
			if (self.verbose) {
				("" + self.number_of_bars).debug("number of bars");
			}
		}),
		StaticText().string_("Quant"),
		TextField().string_(self.quantization).action_({
			| control |
			self.quantization = control.string.asFloat;
			if (self.verbose) {
				("" + self.quantization).debug("quantization");
			}
		}),
		StaticText().string_("Bpm"),
		TextField().string_(self.bpm).action_({
			| control |
			self.next_bpm = control.string.asInteger;
			if (self.verbose) {
				("" + self.next_bpm).debug("next_bpm");
			}
		});
	];
	row2 = [
		StaticText().string_("Recording starts when first event is received!"),
	];
	row3 = [
		StaticText().string_("Quantization and bpm are applied everytime loop restarts."),
	];
	row4 = [
		Button().states_([
			["Recording mode", Color.white, Color.red],
			["Play mode", Color.white, Color.gray]
		]).action_({
			| state |
			self.pause_recording = state.value.asInteger;
		});
	];
	metronome = UserView().animate_(false).drawFunc = {
		| uview |
		if (uview.notNil) {
			Pen.use {
				var lights = self.timesig_nom*self.number_of_bars;
				var gap = uview.bounds.width / lights;
				var cy = uview.bounds.height / 2.0;
				lights.asInteger.do {
					| idx |
					var mw = gap/2;
					var hmw = mw/2;
					var cx = (gap/2) + (idx*gap);
					var current_beat = self.current_beat.floor(1);
					if ( current_beat == idx) {
						if (current_beat.mod(self.timesig_nom) == 0) {
							Pen.fillColor = Color.blue;
						} {
							Pen.fillColor = Color.yellow;
						}
					} /*else*/ {
						Pen.fillColor = Color.gray;
					};
					Pen.fillRect(Rect(cx-hmw, cy-hmw, mw, mw));
					Pen.stroke;
				};
			}
		}
	};
	ui = VLayout(HLayout(*row), HLayout(*row2), HLayout(*row3), HLayout(*row4), VLayout(metronome));
	self.mainwin.layout_(ui);
	self.gui_update_task.play;
});
~midirec.safeReg(\apply_quantization, {
	| self |
	if (self.quantization == 0) {
		self.midi_events.keysValuesDo {
			| key, value |
			self.midi_events[key][\quantized] = self.midi_events[key][\recorded].copy();
			if (self.verbose) {
				self.midi_events[key][\quantized].debug("quantized");
			}
		};
	} /* else */ {
		self.midi_events.keysValuesDo {
			| key, value |
			self.midi_events[key][\quantized] = self.midi_events[key][\recorded].collect({
				| el |
				var evcopy = el.copy();
				var offset = if (evcopy.evtype == \noteoff) { self.quantization - 0.01 } {0.0};
				var need_quant = (evcopy.evtype == \noteon) || (evcopy.evtype == \noteoff) || (evcopy.evtype == \touch) || (evcopy.evtype == \polytouch);
				if (need_quant) {
					"q".debug("yay!");
					evcopy.evbeat = evcopy.evbeat.round(self.quantization) + offset;
				};
				evcopy
			});
			if (self.verbose) {
				self.midi_events[key][\quantized].debug("quantized");
			};
		};
	};
});
~midirec.safeReg(\prepare_play_recorded_events, {
	| self |
	var localcollapsed = [];
	var diff, diffsum;

	self.collapsed_events = [];
	self.bpm = self.next_bpm;
	self.start_time = thisThread.seconds;
	self.apply_quantization;

	// step1 1: collapse all tracks into one
	self.midi_events.keysValuesDo {
		|key, value|
		localcollapsed = localcollapsed ++ self.midi_events[key][\quantized];
	};

	// step 2: sort by evbeat
	self.collapsed_events = localcollapsed.sortBy(\evbeat);
	diff = self.collapsed_events.collect({ |ev|
		ev.evbeat
	}).differentiate[1..];
	diffsum = diff.sum;
	self.collapsed_deltas = diff ++ ((self.timesig_nom*self.number_of_bars) - diffsum);
	if (self.verbose) {
		self.collapsed_events.debug("collapsed events");
		self.collapsed_deltas.debug("collapsed deltas");
	};
});
~midirec.safeReg(\play_recorded_events, {
	| self |
	fork {
		while ({self.interrupt.not}) {
			self.prepare_play_recorded_events; // probably introducing timing problems here...
			self.collapsed_events.do {
				|evt, idx|
				if (self.interrupt.not) {
					var m = self.midiout;
					if (evt.evtype == \noteon) {
						if (self.verbose) {
							"send noteOn!"
						};
						m.noteOn(evt.evchannel, evt.evnote, evt.evvelocity);
					} {
						if (evt.evtype == \noteoff) {
							if (self.verbose) {
								"send noteOff!"
							};
							m.noteOff(evt.evchannel, evt.evnote, evt.evvelocity);
						} {
							if (evt.evtype == \cc) {
								if (self.verbose) {
									"send CC!"
								};
								m.control(evt.evchannel, evt.evcc, evt.evvalue);
							} {
								if (evt.evtype == \bend) {
									if (self.verbose) {
										"send bend!"
									};
									m.bend(evt.evchannel, evt.evvalue);
								} {
									if (evt.evtype == \touch) {
										if (self.verbose) {
											"send touch!"
										};
										m.touch(evt.evchannel, evt.evvalue);
									} {
										if (evt.evtype == \polytouch) {
											if (self.verbose) {
												"send polytouch!"
											};
											m.polytouch(evt.evchannel, evt.evnote, evt.evvalue);
										}
									}
								}
							}
						}
					};
					self.beat_to_time(self.collapsed_deltas[idx]).wait;
				}
			};
			if (self.collapsed_events.isEmpty) {
				self.beat_to_time(self.collapsed_deltas[0]).wait;
			}
		}
	}
});
~midirec.safeReg(\ready_to_record, { | self |
	if (self.start_time.isNil) {
		"Error! Not ready to record becasue start_recording was not called!".postln;
		false;
	};
	if (self.verbose) {"recording initialized"};
	self.pause_recording == 0;
});
~midirec.safeReg(\add_noteon_event, { | self, trackid, time, velocity, note, channel |
	var trackkey = self.trackkey(trackid);
	if (self.ready_to_record) {
		var evt = (\evtype: \noteon,
			\evbeat: self.wrapped_beat_from_time(time - self.start_time).debug("wrapped beat"),
			\evvelocity: velocity,
			\evnote: note,
			\evchannel: channel);
		if (self.verbose.not) {
			self.midi_events[trackkey][\recorded] = self.midi_events[trackkey][\recorded].add(evt);
		} /*else*/ {
			self.midi_events[trackkey][\recorded] = self.midi_events[trackkey][\recorded].add(evt.debug("noteon"));
		};
	}
});
~midirec.safeReg(\add_noteoff_event, { | self, trackid, time, velocity, note, channel |
	var trackkey = self.trackkey(trackid);
	if (self.ready_to_record) {
		var evt = (\evtype: \noteoff,
			\evbeat: self.wrapped_beat_from_time(time - self.start_time),
			\evvelocity: velocity,
			\evnote: note,
			\evchannel: channel);
		if (self.verbose.not) {
			self.midi_events[trackkey][\recorded] = self.midi_events[trackkey][\recorded].add(evt);
		} /* else */ {
			self.midi_events[trackkey][\recorded] = self.midi_events[trackkey][\recorded].add(evt.debug("noteoff"));
		}
	}
});
~midirec.safeReg(\add_controlchange_event, { | self, trackid, time, value, cc, channel |
	var trackkey = self.trackkey(trackid);
	if (self.ready_to_record) {
		var evt = (\evtype: \cc,
			\evbeat: self.wrapped_beat_from_time(time - self.start_time),
			\evvalue: value,
			\evcc: cc,
			\evchannel: channel);
		if (self.verbose.not) {
			self.midi_events[trackkey][\recorded] = self.midi_events[trackkey][\recorded].add(evt);
		} /* else */ {
			self.midi_events[trackkey][\recorded] = self.midi_events[trackkey][\recorded].add(evt.debug("cc"));
		}
	}
});
~midirec.safeReg(\add_pitchbend_event, { | self, trackid, time, value, channel |
	var trackkey = self.trackkey(trackid);
	if (self.ready_to_record) {
		var evt = (\evtype: \bend,
			\evbeat: self.wrapped_beat_from_time(time - self.start_time),
			\evvalue: value,
			\evchannel: channel
		);
		if (self.verbose.not) {
			self.midi_events[trackkey][\recorded] = self.midi_events[trackkey][\recorded].add(evt);
		} /* else */ {
			self.midi_events[trackkey][\recorded] = self.midi_events[trackkey][\recorded].add(evt.debug("bend"));
		}
	}
});
~midirec.safeReg(\add_touch_event, { | self, trackid, time, value, channel |
	var trackkey = self.trackkey(trackid);
	if (self.ready_to_record) {
		var evt = (\evtype: \touch,
			\evbeat: self.wrapped_beat_from_time(time - self.start_time),
			\evvalue: value,
			\evchannel: channel
		);
		if (self.verbose.not) {
			self.midi_events[trackkey][\recorded] = self.midi_events[trackkey][\recorded].add(evt);
		} /* else */ {
			self.midi_events[trackkey][\recorded] = self.midi_events[trackkey][\recorded].add(evt.debug("touch"));
		}
	}
});
~midirec.safeReg(\add_polytouch_event, { | self, trackid, time, value, note, channel |
	var trackkey = self.trackkey(trackid);
	if (self.ready_to_record) {
		var evt = (\evtype: \polytouch,
			\evbeat: self.wrapped_beat_from_time(time - self.start_time),
			\evvalue: value,
			\evnote: note,
			\evchannel: channel);
		if (self.verbose.not) {
			self.midi_events[trackkey][\recorded] = self.midi_events[trackkey][\recorded].add(evt);
		} /* else */ {
			self.midi_events[trackkey][\recorded] = self.midi_events[trackkey][\recorded].add(evt.debug("polytouch"));
		}
	}
});
~midirec.safeReg(\noteOnHandler, {
	// val (velocity), num (note num), chan, and src
	| self, val, num, chan, src |
	var time = thisThread.seconds;
	self.check_preconditions(self.current_track);
	self.add_noteon_event(self.current_track, time, val, num, chan);
});
~midirec.safeReg(\noteOffHandler, {
	// val (velocity), num (note num), chan, and src
	| self, val, num, chan, src |
	var time = thisThread.seconds;
	self.check_preconditions(self.current_track);
	self.add_noteoff_event(self.current_track, time, val, num, chan);
});
~midirec.safeReg(\controlChangeHandler, {
	| self, val, num, chan, src |
	var time = thisThread.seconds;
	self.check_preconditions(self.current_track);
	self.add_controlchange_event(self.current_track, time, val, num, chan);
});
~midirec.safeReg(\pitchBendHandler, {
	| self, val, chan, src |
	var time = thisThread.seconds;
	self.check_preconditions(self.current_track);
	self.add_pitchbend_event(self.current_track, time, val, chan);
});
~midirec.safeReg(\touchHandler, {
	| self, val, chan, src |
	var time = thisThread.seconds;
	self.check_preconditions(self.current_track);
	self.add_touch_event(self.current_track, time, val, chan);
});
~midirec.safeReg(\polytouchHandler, {
	| self, val, num, chan, src |
	var time = thisThread.seconds;
	self.check_preconditions(self.current_track);
	self.add_polytouch_event(self.current_track, time, val, num, chan);
});
~midirec.safeReg(\all_notes_off, {
	|self |
	16.do({
		|ch|
		self.midiout.allNotesOff(ch);
	})
});


MIDIdef.noteOn(\noteOn, {|val, num, chan, src| ~midirec.noteOnHandler(val, num, chan, src)});
MIDIdef.noteOff(\noteOff, {|val, num, chan, src| ~midirec.noteOffHandler(val, num, chan, src)});
MIDIdef.cc(\ctrlChng, { |val, num, chan, src | ~midirec.controlChangeHandler(val, num, chan, src)});
MIDIdef.bend(\pitchBend, {|val, chan, src | ~midirec.pitchBendHandler(val, chan, src)});
MIDIdef.touch(\touch, {|val, num, chan, src | ~midirec.touchHandler(val, num, chan, src)});
MIDIdef.touch(\polytouch, {|val, num, chan, src | ~midirec.polytouchHandler(val, num, chan, src)});

~midirec.show_gui;

CmdPeriod.doOnce({
	~midirec.stopAll;
});

)

