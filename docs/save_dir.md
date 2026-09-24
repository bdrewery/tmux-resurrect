# Resurrect save dir

By default Tmux environment is saved to a file in `~/.tmux/resurrect` dir.
Change this with:

    set -g @resurrect-dir '/some/path'

Using environment variables or shell interpolation in this option is not
allowed as the string is used literally. So the following won't do what is
expected:

    set -g @resurrect-dir '/path/$MY_VAR/$(some_executable)'

Only the following variables and special chars are allowed:
`$HOME`, `$HOSTNAME`, and `~`.

### Staging dir

Pane contents are kept as an archive in the save dir.  On restore, the
per-pane files are unpacked into a private directory created with `mktemp -d`
under a staging dir, rather than into the save dir, which may be on a slow
network filesystem.  The staging dir defaults to `$TMPDIR`, or `/tmp` if that
is unset.  Change it with:

    set -g @resurrect-staging-dir '/some/local/path'

The same variables as `@resurrect-dir` are allowed.
