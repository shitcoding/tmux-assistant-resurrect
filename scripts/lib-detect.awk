# Shared awk assistant detector.
#
# Loaded by save-assistant-sessions.sh together with its process-tree program.
# Tests set classify_only=1 to exercise this exact production implementation
# without maintaining another copy of the patterns.

function detect_tool(line) {
	if      (line ~ /(^claude( |$)|\/claude( |$))/)                               return "claude"
	else if (line ~ /(^copilot( |$)|\/copilot( |$))/)                             return "copilot"
	else if (line ~ /(^opencode( |$)|\/opencode( |$))/ && line !~ /opencode run /) return "opencode"
	else if (line ~ /(^codex( |$)|\/codex( |$))/)                                 return "codex"
	else if (line ~ /(^pi( |$)|\/pi( |$))/)                                       return "pi"
	else if (line ~ /(^omp( |$)|\/omp( |$))/ && line !~ /__omp_worker_/)          return "omp"
	else if (line ~ /(^grok( |$)|\/grok( |$))/)                                   return "grok"
	return ""
}

classify_only {
	detected_tool = detect_tool($0)
	if (detected_tool != "") print detected_tool
	next
}
