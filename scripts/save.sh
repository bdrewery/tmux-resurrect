#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/spinner_helpers.sh"

# delimiters
d=$'\t'
delimiter=$'\t'

# if "quiet" script produces no output
SCRIPT_OUTPUT="$1"

grouped_sessions_format() {
	local format
	format+="#{session_grouped}"
	format+="${delimiter}"
	format+="#{session_group}"
	format+="${delimiter}"
	format+="#{session_id}"
	format+="${delimiter}"
	format+="#{session_name}"
	echo "$format"
}

pane_format() {
	local format
	format+="pane"
	format+="${delimiter}"
	format+="#{session_name}"
	format+="${delimiter}"
	format+="#{window_index}"
	format+="${delimiter}"
	format+="#{window_active}"
	format+="${delimiter}"
	format+=":#{window_flags}"
	format+="${delimiter}"
	format+="#{pane_index}"
	format+="${delimiter}"
	# ':' guard: pane_title may legitimately be empty, and the readers below
	# split on IFS=$'\t'.  Tab is IFS whitespace, so a run of tabs collapses
	# into one separator and every later field shifts left by one.  Titles go
	# empty when a program sets one via OSC 2 and clears it on exit.
	#
	# Reported upstream repeatedly and still unmerged.  The identical ':' fix
	# is https://github.com/tmux-plugins/tmux-resurrect/pull/583; see also
	# pull/564, pull/581, pull/520, and the abandoned pull/582 and pull/570.
	format+=":#{pane_title}"
	format+="${delimiter}"
	format+=":#{pane_current_path}"
	format+="${delimiter}"
	format+="#{pane_active}"
	format+="${delimiter}"
	format+="#{pane_current_command}"
	format+="${delimiter}"
	format+="#{pane_pid}"
	format+="${delimiter}"
	format+="#{history_size}"
	echo "$format"
}

window_format() {
	local format
	format+="window"
	format+="${delimiter}"
	format+="#{session_name}"
	format+="${delimiter}"
	format+="#{window_index}"
	format+="${delimiter}"
	format+=":#{window_name}"
	format+="${delimiter}"
	format+="#{window_active}"
	format+="${delimiter}"
	format+=":#{window_flags}"
	format+="${delimiter}"
	format+="#{window_layout}"
	echo "$format"
}

state_format() {
	local format
	format+="state"
	format+="${delimiter}"
	format+="#{client_session}"
	format+="${delimiter}"
	format+="#{client_last_session}"
	echo "$format"
}

dump_panes_raw() {
	tmux list-panes -a -F "$(pane_format)"
}

dump_windows_raw(){
	tmux list-windows -a -F "$(window_format)"
}

toggle_window_zoom() {
	local target="$1"
	tmux resize-pane -Z -t "$target"
}

_save_command_strategy_file() {
	local save_command_strategy="$(get_tmux_option "$save_command_strategy_option" "$default_save_command_strategy")"
	local strategy_file="$CURRENT_DIR/../save_command_strategies/${save_command_strategy}.sh"
	local default_strategy_file="$CURRENT_DIR/../save_command_strategies/${default_save_command_strategy}.sh"
	if [ -e "$strategy_file" ]; then # strategy file exists?
		echo "$strategy_file"
	else
		echo "$default_strategy_file"
	fi
}

pane_full_command() {
	local pane_pid="$1"
	local strategy_file="$(_save_command_strategy_file)"
	# execute strategy script to get pane full command
	$strategy_file "$pane_pid"
}

number_nonempty_lines_on_screen() {
	local pane_id="$1"
	tmux capture-pane -pJ -t "$pane_id" |
		sed '/^$/d' |
		wc -l |
		sed 's/ //g'
}

# tests if there was any command output in the current pane
pane_has_any_content() {
	local pane_id="$1"
	local history_size="$(tmux display -p -t "$pane_id" -F "#{history_size}")"
	local cursor_y="$(tmux display -p -t "$pane_id" -F "#{cursor_y}")"
	# doing "cheap" tests first
	[ "$history_size" -gt 0 ] || # history has any content?
		[ "$cursor_y" -gt 0 ] || # cursor not in first line?
		[ "$(number_nonempty_lines_on_screen "$pane_id")" -gt 1 ]
}

capture_pane_contents() {
	local pane_id="$1"
	local start_line="-$2"
	local pane_contents_area="$3"
	if pane_has_any_content "$pane_id"; then
		if [ "$pane_contents_area" = "visible" ]; then
			start_line="0"
		fi
		# the printf hack below removes *trailing* empty lines
		printf '%s\n' "$(tmux capture-pane -epJ -S "$start_line" -t "$pane_id")" > "$(pane_contents_file "save" "$pane_id")"
	fi
}

get_active_window_index() {
	local session_name="$1"
	tmux list-windows -t "$session_name" -F "#{window_flags} #{window_index}" |
		awk '$1 ~ /\*/ { print $2; }'
}

get_alternate_window_index() {
	local session_name="$1"
	tmux list-windows -t "$session_name" -F "#{window_flags} #{window_index}" |
		awk '$1 ~ /-/ { print $2; }'
}

dump_grouped_sessions() {
	local current_session_group=""
	local original_session
	tmux list-sessions -F "$(grouped_sessions_format)" |
		grep "^1" |
		cut -c 3- |
		sort |
		while IFS=$d read session_group session_id session_name; do
			if [ "$session_group" != "$current_session_group" ]; then
				# this session is the original/first session in the group
				original_session="$session_name"
				current_session_group="$session_group"
			else
				# this session "points" to the original session
				active_window_index="$(get_active_window_index "$session_name")"
				alternate_window_index="$(get_alternate_window_index "$session_name")"
				echo "grouped_session${d}${session_name}${d}${original_session}${d}:${alternate_window_index}${d}:${active_window_index}"
			fi
		done
}

fetch_and_dump_grouped_sessions(){
	local grouped_sessions_dump="$(dump_grouped_sessions)"
	get_grouped_sessions "$grouped_sessions_dump"
	if [ -n "$grouped_sessions_dump" ]; then
		echo "$grouped_sessions_dump"
	fi
}

# translates pane pid to process command running inside a pane
dump_panes() {
	local full_command
	dump_panes_raw |
		while IFS=$d read line_type session_name window_number window_active window_flags pane_index pane_title dir pane_active pane_command pane_pid history_size; do
			# not saving panes from grouped sessions
			if is_session_grouped "$session_name"; then
				continue
			fi
			full_command="$(pane_full_command $pane_pid)"
			dir=$(echo $dir | sed 's/ /\\ /') # escape all spaces in directory path
			echo "${line_type}${d}${session_name}${d}${window_number}${d}${window_active}${d}${window_flags}${d}${pane_index}${d}${pane_title}${d}${dir}${d}${pane_active}${d}${pane_command}${d}:${full_command}"
		done
}

dump_windows() {
	dump_windows_raw |
		while IFS=$d read line_type session_name window_index window_name window_active window_flags window_layout; do
			# not saving windows from grouped sessions
			if is_session_grouped "$session_name"; then
				continue
			fi
			automatic_rename="$(tmux show-window-options -vt "${session_name}:${window_index}" automatic-rename)"
			# If the option was unset, use ":" as a placeholder.
			[ -z "${automatic_rename}" ] && automatic_rename=":"
			echo "${line_type}${d}${session_name}${d}${window_index}${d}${window_name}${d}${window_active}${d}${window_flags}${d}${window_layout}${d}${automatic_rename}"
		done
}

dump_state() {
	tmux display-message -p "$(state_format)"
}

dump_pane_contents() {
	local pane_contents_area="$(get_tmux_option "$pane_contents_area_option" "$default_pane_contents_area")"
	# Option name and mechanism adapted from josh-stephens' unmerged
	# https://github.com/tmux-plugins/tmux-resurrect/pull/583.  The name is
	# kept identical deliberately: if that lands upstream, configs setting it
	# keep working without change.
	local capture_depth="$(get_tmux_option "$capture_depth_option" "$default_capture_depth")"
	# Reject anything non-numeric here rather than letting every pane's test
	# below fail: an unusable value means "no cap", same as the default.
	case "$capture_depth" in
	''|*[!0-9]*) capture_depth=0 ;;
	esac
	dump_panes_raw |
		while IFS=$d read line_type session_name window_number window_active window_flags pane_index pane_title dir pane_active pane_command pane_pid history_size; do
			if [ "$capture_depth" -gt 0 ] && [ "$history_size" -gt "$capture_depth" ]; then
				history_size="$capture_depth"
			fi
			capture_pane_contents "${session_name}:${window_number}.${pane_index}" "$history_size" "$pane_contents_area"
		done
}

remove_old_backups() {
	# remove resurrect files older than 30 days (default), but keep at least 5 copies of backup.
	local delete_after="$(get_tmux_option "$delete_backup_after_option" "$default_delete_backup_after")"
	local -a files
	files=($(ls -t $(resurrect_dir)/${RESURRECT_FILE_PREFIX}_*.${RESURRECT_FILE_EXTENSION} | tail -n +6))
	[[ ${#files[@]} -eq 0 ]] ||
		find "${files[@]}" -type f -mtime "+${delete_after}" -exec rm -v "{}" \; > /dev/null
}

save_all() {
	local resurrect_file_path="$(resurrect_file_path)"
	local last_resurrect_file="$(last_resurrect_file)"
	mkdir -p "$(resurrect_dir)"
	fetch_and_dump_grouped_sessions > "$resurrect_file_path"
	dump_panes   >> "$resurrect_file_path"
	dump_windows >> "$resurrect_file_path"
	dump_state   >> "$resurrect_file_path"
	execute_hook "post-save-layout" "$resurrect_file_path"
	# Check adapted from josh-stephens' unmerged
	# https://github.com/tmux-plugins/tmux-resurrect/pull/583, with the
	# message moved to main so an aborted save is not announced as a
	# successful one.
	#
	# A dump with no window or pane lines means tmux answered nothing, not
	# that there was nothing to save.  Discard it here, before the block
	# below can point 'last' at a file that would restore an empty session
	# over a good one.  The file is uniquely named per save, so dropping it
	# leaves the previous save untouched.
	if ! \grep -q '^window' "$resurrect_file_path" ||
		! \grep -q '^pane' "$resurrect_file_path"; then
		rm -f "$resurrect_file_path"
		return 1
	fi
	if files_differ "$resurrect_file_path" "$last_resurrect_file"; then
		ln -fs "$(basename "$resurrect_file_path")" "$last_resurrect_file"
	else
		rm "$resurrect_file_path"
	fi
	if capture_pane_contents_option_on; then
		mkdir -p "$(pane_contents_dir "save")"
		dump_pane_contents
		pane_contents_create_archive
		rm "$(pane_contents_dir "save")"/*
	fi
	remove_old_backups
	execute_hook "post-save-all"
}

show_output() {
	[ "$SCRIPT_OUTPUT" != "quiet" ]
}

main() {
	local exit_status=0
	if supported_tmux_version_ok; then
		if show_output; then
			start_spinner "Saving..." "Tmux environment saved!"
		fi
		save_all || exit_status="$?"
		if show_output; then
			if [ "$exit_status" -eq 0 ]; then
				stop_spinner
				display_message "Tmux environment saved!"
			else
				# stop_spinner sends SIGTERM, and the spinner traps it
				# to announce success.  Bypass the trap so an aborted
				# save cannot report itself as having worked.
				kill -KILL "$SPINNER_PID" 2>/dev/null
				display_message "tmux-resurrect: save aborted, tmux returned an incomplete dump"
			fi
		fi
	fi
	return "$exit_status"
}
main
