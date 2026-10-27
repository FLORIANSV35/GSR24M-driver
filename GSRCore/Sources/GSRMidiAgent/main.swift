import Foundation
import GSRCore

// gsrmidiagent: runs in the user's session (LaunchAgent). Virtual MIDI ports for the card, and the Pro Tools translation.
setvbuf(stdout, nil, _IOLBF, 0)
guard let agent = MIDIAgent() else { exit(1) }
agent.run()
