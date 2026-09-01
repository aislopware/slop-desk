//! The zsh half of the bridge, as a Rust constant.
//!
//! ## Why any zsh at all
//! zsh's completion system is not a data file that can be read. A completion function is program
//! text that runs inside `zle`, reaches for the shell's own dynamic scope, and reports what it
//! found by CALLING `compadd`. `-a`/`-k`/`-d` name arrays that exist only in the calling function's
//! frame at the instant of the call, so nothing outside a live zsh can expand them. That is the
//! whole reason this text exists: it is the smallest program that can be inside zsh while the
//! answer is being produced, and every decision it makes is reported outward as flat lines.
//!
//! ## Why a `const` and not a script in the tree
//! `docs/60`'s campaign deleted this repository's shell scripts because each was LOGIC spelled in a
//! second language. This is the opposite case and the distinction is worth stating: the text below
//! is a PROTOCOL ADAPTER for zsh, in the only language zsh runs, and it has exactly one caller.
//! Shipping it as a file would give it a second life — sourceable, editable, drift-able, and
//! greppable as "a shell script we still have". As a constant it is compiled into the one crate
//! that writes it, cannot be edited without a rebuild, and its record format is pinned by
//! [`crate::parse`]'s tests on the other side of the same crate. The session writes it into its own
//! temp directory at spawn and `source`s it, because a pty in canonical mode truncates an input
//! line at `MAX_CANON` (~1024 bytes) and this is far longer than that.
//!
//! ## What it must never do
//! It must never change what the user's own completion would insert. Every override here reports
//! and falls through: `compadd` ALWAYS reaches the builtin, so the status its caller reads is the
//! real one. An override that returned early would make `_describe` skip the pass that carries the
//! descriptions — a measured failure, not a hypothetical one.

/// The capture half, `source`d into the captive shell at spawn.
pub const SETUP: &str = r#"
# The capture half, in zsh because only zsh can expand `-a`/`-k` array names and `-d` display
# arrays. Everything it emits is line-oriented and unquoted, so the Rust half is a plain reader.
#
# Record stream, per `compadd` call that actually ADDS matches:
#   CALL
#   I<IPREFIX>  P<PREFIX>  S<SUFFIX>  J<ISUFFIX>   -- the line context, for the exact replace range
#   X<-P>  Y<-p>  Z<-s>  W<-S>                     -- the affixes that are inserted with a match
#   F<flags>                                       -- the flags that change what an ACCEPT inserts
#   M<match>\t<display>                            -- one per candidate; display empty when none
#
# `BEGIN <seq>` opens every request and `END <seq>` closes it. Both carry the sequence number and
# the records between them do not, which is what lets the reader discard a whole abandoned answer:
# a request given up on at the deadline keeps writing, and without the opener its late records would
# land in front of the next one's and read as part of it.

_slopdesk_zc_emit() { builtin print -rl -- "$@" >> $SLOPDESK_ZC_OUT }

# `compadd`'s flags cluster the way getopt's do: the booleans pack into one token and the LAST
# letter may take its argument either attached or as the next word — `-2V -default-`, `-E11` and
# `-qS=` are all real calls out of one `ls --`. So the scan is per CHARACTER, not per token; a
# token-level reader silently drops most of what `_arguments` sends.
_slopdesk_zc_bool='akqQfenUl12C'
_slopdesk_zc_arg='PSpsiIWdJVXxrRMFEAOD'

compadd() {
  emulate -L zsh
  local -a args matches displays
  args=("$@")
  local apre='' hpre='' hsuf='' asuf='' darr='' flags='' word ch arg
  integer i=1 j taken adds=1 arrays=0 assoc=0 unknown=0

  while (( i <= $#args )); do
    word=$args[i]
    # `-` ends the flags exactly as `--` does, and `_arguments` uses it.
    [[ $word == - || $word == -- ]] && { (( i++ )); break }
    [[ $word != -?* ]] && break
    j=2
    taken=0
    while (( j <= $#word )); do
      ch=$word[j]
      arg=$word[j+1,-1]
      # Every pattern test quotes `$ch`: an unknown flag character could otherwise be read as a
      # glob, and an error raised inside this override aborts the whole completion widget.
      if [[ $_slopdesk_zc_bool == *"$ch"* ]]; then
        [[ $ch == a ]] && arrays=1
        [[ $ch == k ]] && assoc=1
        # `-Q` means the matches carry their own quoting and go in verbatim; `-U` means they are
        # not matched against the line at all, so the PREFIX arithmetic that gives an exact
        # replacement range does not describe them. Both have to cross.
        [[ $ch == [QU] ]] && flags="$flags$ch"
        (( j++ ))
        continue
      fi
      if [[ $_slopdesk_zc_arg == *"$ch"* ]]; then
        [[ -z $arg ]] && { arg=$args[i+1]; taken=1 }
        case $ch in
          P) apre=$arg ;;
          S) asuf=$arg ;;
          p) hpre=$arg ;;
          s) hsuf=$arg ;;
          d) darr=$arg ;;
          # `-O`/`-A` store the completions in an array instead of offering them, and `-D` filters
          # a parallel one — none of the three puts anything on the line, and `-D` in particular is
          # the pass `_describe` makes BEFORE the one that carries the descriptions.
          O|A|D) adds=0 ;;
        esac
        break
      fi
      # `-o`'s argument is optional: attached, or the next word when that is an order name.
      if [[ $ch == o ]]; then
        [[ -z $arg && $args[i+1] == [a-z]* ]] && taken=1
        break
      fi
      # A flag this build does not know could be one that changes what an accepted match inserts.
      # Reporting nothing is the one-sided-safe answer: a missing candidate costs a completion, a
      # wrong one writes the user's command line for them.
      unknown=1
      break
    done
    (( unknown )) && break
    (( i += 1 + taken ))
  done

  if (( adds && !unknown )); then
    for word in $args[i,-1]; do
      if (( arrays )); then
        builtin eval "matches+=( \${$word} )"
      elif (( assoc )); then
        builtin eval "matches+=( \${(k)$word} )"
      else
        matches+=( $word )
      fi
    done
    [[ -n $darr ]] && displays=( ${(P)darr} )
    if (( $#matches )); then
      _slopdesk_zc_emit CALL "I$IPREFIX" "P$PREFIX" "S$SUFFIX" "J$ISUFFIX" \
                         "X$apre" "Y$hpre" "Z$hsuf" "W$asuf" "F$flags"
      integer n=1
      for word in $matches; do
        # The stream is line-oriented and tab-split, so a match carrying either character cannot be
        # reported without corrupting the record that follows it. Such a name is legal and vanishing
        # rare, and dropping it is the one-sided-safe answer: the user loses one completion instead
        # of accepting one that inserts the wrong bytes.
        [[ $word == *[$'\n\t']* ]] || _slopdesk_zc_emit "M$word	${displays[n]//[$'\n\t']/ }"
        (( n++ ))
      done
    fi
  fi
  # ALWAYS through to the builtin, whatever was reported. A `compadd` that does not reach it
  # returns a status its caller reads as "matches added", and `_describe` then skips the very pass
  # that had them — one `ls --` went from 74 calls to 1 that way.
  builtin compadd "$@"
}

# `_main_complete` is only legal inside a COMPLETION widget, and the two `compstate` clears are what
# stop the second request reusing the first one's latched menu instead of calling `compadd` again.
_slopdesk_zc() { compstate[insert]=; compstate[list]=; _main_complete }
zle -C slopdesk-zc complete-word _slopdesk_zc

# A normal widget drives it, so a request never has to be typed: buffer, cursor and cwd arrive as
# files and no text ever needs escaping for a terminal.
_slopdesk_zc_drive() {
  local raw seq
  raw="$(<$SLOPDESK_ZC_REQ)"
  local -a lines=("${(@f)raw}")
  seq=$lines[1]
  builtin cd -q -- "$lines[3]" 2>/dev/null
  BUFFER="${(j:
:)lines[4,-1]}"
  CURSOR=$lines[2]
  builtin print -r -- "BEGIN $seq" >> $SLOPDESK_ZC_OUT
  zle slopdesk-zc
  builtin print -r -- "END $seq" >> $SLOPDESK_ZC_OUT
  BUFFER=""; CURSOR=0
}
zle -N slopdesk-zc-drive _slopdesk_zc_drive
bindkey "^X^A" slopdesk-zc-drive

builtin print -r -- "READY" >> $SLOPDESK_ZC_OUT
"#;
