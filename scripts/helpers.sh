if [ -d "$HOME/.tmux/resurrect" ]; then
        default_resurrect_dir="$HOME/.tmux/resurrect"
else
        default_resurrect_dir="${XDG_DATA_HOME:-$HOME/.local/share}"/tmux/resurrect
fi
resurrect_dir_option="@resurrect-dir"

SUPPORTED_VERSION="1.9"
RESURRECT_FILE_PREFIX="tmux_resurrect"
RESURRECT_FILE_EXTENSION="txt"
_RESURRECT_DIR=""
_RESURRECT_FILE_PATH=""
_RESTORE_DIR=""
_SAVE_DIR=""
staging_dir_option="@resurrect-staging-dir"

d=$'\t'

# helper functions
get_tmux_option() {
	local option="$1"
	local default_value="$2"
	local option_value=$(tmux show-option -gqv "$option")
	if [ -z "$option_value" ]; then
		echo "$default_value"
	else
		echo "$option_value"
	fi
}

# Ensures a message is displayed for 5 seconds in tmux prompt.
# Does not override the 'display-time' tmux option.
display_message() {
	local message="$1"

	# display_duration defaults to 5 seconds, if not passed as an argument
	if [ "$#" -eq 2 ]; then
		local display_duration="$2"
	else
		local display_duration="5000"
	fi

	# saves user-set 'display-time' option
	local saved_display_time=$(get_tmux_option "display-time" "750")

	# sets message display time to 5 seconds
	tmux set-option -gq display-time "$display_duration"

	# displays message
	tmux display-message "$message"

	# restores original 'display-time' value
	tmux set-option -gq display-time "$saved_display_time"
}


supported_tmux_version_ok() {
	$CURRENT_DIR/check_tmux_version.sh "$SUPPORTED_VERSION"
}

remove_first_char() {
	echo "$1" | cut -c2-
}

capture_pane_contents_option_on() {
	local option="$(get_tmux_option "$pane_contents_option" "off")"
	[ "$option" == "on" ]
}

files_differ() {
	! cmp -s "$1" "$2"
}

get_grouped_sessions() {
	local grouped_sessions_dump="$1"
	export GROUPED_SESSIONS="${d}$(echo "$grouped_sessions_dump" | cut -f2 -d"$d" | tr "\\n" "$d")"
}

is_session_grouped() {
	local session_name="$1"
	[[ "$GROUPED_SESSIONS" == *"${d}${session_name}${d}"* ]]
}

# pane content file helpers

pane_contents_create_archive() {
	tar cf - -C "$_SAVE_DIR" ./pane_contents/ |
		gzip > "$(pane_contents_archive_file)"
}

# Each restore unpacks into a directory of its own from mktemp, so a pane
# whose contents were not saved this time cannot pick up an older capture, and
# nothing from a previous restore has to be cleared first.  The panes empty and
# remove the directory as they read it (see pane_creation_command).  Removing
# the files at the end of restore instead raced the panes' own `cat` of them:
# on a slow filesystem such as NFS, or with a shell that starts slowly, the
# files were gone before the panes read them.  Deferring that cleanup was
# proposed upstream, unmerged as of this commit:
#   https://github.com/tmux-plugins/tmux-resurrect/pull/528
pane_content_files_restore_from_archive() {
	local archive_file="$(pane_contents_archive_file)"
	if [ -f "$archive_file" ]; then
		remove_legacy_restore_dir
		remove_stale_restore_dirs
		_RESTORE_DIR="$(staging_mktemp "restore")" || return
		mkdir "$_RESTORE_DIR/pane_contents"
		gzip -d < "$archive_file" |
			tar xf - -C "$_RESTORE_DIR"
	fi
}

# Restore used to unpack into <resurrect-dir>/restore, which nothing reads any
# more.  Drop what an older version left there.
remove_legacy_restore_dir() {
	local legacy="$(resurrect_dir)/restore"
	rm -f "$legacy/pane_contents"/*
	rmdir "$legacy/pane_contents" "$legacy" 2>/dev/null
}

# A restore directory outlives restore.sh until its last pane has read its
# file.  One whose panes never ran, say because they were killed first or
# were not recreated, is left behind; clear those out once they are an hour
# old, which no restore still being read from can be.
#
# -mindepth 1 keeps the staging dir itself out of it, whatever it is named.
# Without a socket name the pattern would match every socket's directories,
# so skip the sweep rather than guess.
remove_stale_restore_dirs() {
	local socket_name
	socket_name="$(staging_socket_name)" || return 0
	find "$(staging_dir)" -mindepth 1 -maxdepth 1 -type d -user "$(id -u)" \
		-name "tmux-resurrect-restore-${socket_name}.*" -mmin +60 \
		-exec rm -rf {} + 2>/dev/null
}

# path helpers

resurrect_dir() {
	if [ -z "$_RESURRECT_DIR" ]; then
		local path="$(get_tmux_option "$resurrect_dir_option" "$default_resurrect_dir")"
		# expands tilde, $HOME and $HOSTNAME if used in @resurrect-dir
		echo "$path" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$(hostname),g; s,\~,$HOME,g"
	else
		echo "$_RESURRECT_DIR"
	fi
}
_RESURRECT_DIR="$(resurrect_dir)"

resurrect_file_path() {
	if [ -z "$_RESURRECT_FILE_PATH" ]; then
		local timestamp="$(date +"%Y%m%dT%H%M%S")"
		echo "$(resurrect_dir)/${RESURRECT_FILE_PREFIX}_${timestamp}.${RESURRECT_FILE_EXTENSION}"
	else
		echo "$_RESURRECT_FILE_PATH"
	fi
}
_RESURRECT_FILE_PATH="$(resurrect_file_path)"

# Parent of the per-run scratch directories holding the per-pane contents
# files.  They are kept off @resurrect-dir: that is often on NFS, where every
# per-pane file costs round trips, and only the archive has to persist there.
staging_dir() {
	local path="$(get_tmux_option "$staging_dir_option" "${TMPDIR:-/tmp}")"
	# same expansions as @resurrect-dir
	echo "$path" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$(hostname),g; s,\~,$HOME,g"
}

# The tmux socket name, made safe for a file name, so that the scratch
# directories of servers on different sockets can be told apart.  Fails if
# tmux does not say.
staging_socket_name() {
	local socket_path="$(tmux display-message -p '#{socket_path}' 2>/dev/null)"
	[ -n "$socket_path" ] || return 1
	basename "$socket_path" | tr -c 'A-Za-z0-9._\n-' '_'
}

# A fresh private directory for one save or restore.  mktemp creates it under
# a name nobody could have predicted and fails rather than reuse something
# already there, so a shared /tmp cannot be used to plant a symlink on us.
staging_mktemp() {
	local kind="$1"
	local socket_name
	# "unknown" rather than "default", which is tmux's own default socket
	# name and would put these in reach of that socket's sweep.
	socket_name="$(staging_socket_name)" || socket_name="unknown"
	mktemp -d "$(staging_dir)/tmux-resurrect-${kind}-${socket_name}.XXXXXX"
}

last_resurrect_file() {
	echo "$(resurrect_dir)/last"
}

pane_contents_dir() {
	if [ "$1" = "restore" ]; then
		echo "$_RESTORE_DIR/pane_contents/"
	else
		echo "$_SAVE_DIR/pane_contents/"
	fi
}

pane_contents_file() {
	local save_or_restore="$1"
	local pane_id="$2"
	echo "$(pane_contents_dir "$save_or_restore")/pane-${pane_id}"
}

pane_contents_file_exists() {
	local pane_id="$1"
	[ -n "$_RESTORE_DIR" ] &&
		[ -f "$(pane_contents_file "restore" "$pane_id")" ]
}

pane_contents_archive_file() {
	echo "$(resurrect_dir)/pane_contents.tar.gz"
}

execute_hook() {
	local kind="$1"
	shift
	local args="" hook=""

	hook=$(get_tmux_option "$hook_prefix$kind" "")

	# If there are any args, pass them to the hook (in a way that preserves/copes
	# with spaces and unusual characters.
	if [ "$#" -gt 0 ]; then
		printf -v args "%q " "$@"
	fi

	if [ -n "$hook" ]; then
		eval "$hook $args"
	fi
}
