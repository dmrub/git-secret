#!/usr/bin/env bash

# Folders:
_SECRETS_DIR=${SECRETS_DIR:-".gitsecret"}
# if SECRETS_DIR env var is set, use that instead of .gitsecret
# for full path to secrets dir, use _get_secrets_dir()
# from _git_secret_tools.sh
_SECRETS_DIR_KEYS="${_SECRETS_DIR}/keys"
_SECRETS_DIR_PATHS="${_SECRETS_DIR}/paths"

# Files:
_SECRETS_DIR_KEYS_TRUSTDB="${_SECRETS_DIR_KEYS}/trustdb.gpg"

_SECRETS_DIR_PATHS_MAPPING="${_SECRETS_DIR_PATHS}/mapping.cfg"

# _SECRETS_VERBOSE is expected to be empty or '1'.
# Empty means 'off', any other value means 'on'.
# shellcheck disable=SC2153
if [[ -n "$SECRETS_VERBOSE" ]] && [[ "$SECRETS_VERBOSE" -ne 0 ]]; then
  # shellcheck disable=SC2034
  _SECRETS_VERBOSE='1'
fi

: "${SECRETS_EXTENSION:=".secret"}"

# Commands:
: "${SECRETS_GPG_COMMAND:="gpg"}"
: "${SECRETS_CHECKSUM_COMMAND:="_os_based __sha256"}"
: "${SECRETS_OCTAL_PERMS_COMMAND:="_os_based __get_octal_perms"}"
: "${SECRETS_EPOCH_TO_DATE:="_os_based __epoch_to_date"}"

# Temp Dir:
: "${TMPDIR:=/tmp}"

# AWK scripts:
# shellcheck disable=2016
AWK_FSDB_HAS_RECORD='
BEGIN { FS=":"; OFS=":"; cnt=0; }
{
  if ( key == $1 )
  {
    cnt++
  }
}
END { if ( cnt > 0 ) print "0"; else print "1"; }
'

# shellcheck disable=2016
AWK_FSDB_RM_RECORD='
BEGIN { FS=":"; OFS=":"; }
{
  if ( key != $1 )
  {
    print $1,$2;
  }
}
'

# shellcheck disable=2016
AWK_FSDB_CLEAR_HASHES='
BEGIN { FS=":"; OFS=":"; }
{
  print $1,"";
}
'

# shellcheck disable=2016
AWK_GPG_VER_CHECK='
/^gpg/{
  version=$3
  n=split(version,array,".")
  if( n >= 2) {
    if(array[1] >= 2)
    {
      if(array[2] >= 1)
      {
        print 1
      }
      else
      {
        print 0
      }
    }
    else
    {
      print 0
    }
  }
  else if(array[1] >= 2)
  {
    print 1
  }
  else
  {
    print 0
  }
}
'

# This is 1 for gpg version 2.1 or greater, otherwise 0
GPG_VER_MIN_21="$($SECRETS_GPG_COMMAND --version | gawk "$AWK_GPG_VER_CHECK")"


# Bash:

function _function_exists {
  local function_name="$1" # required

  declare -f -F "$function_name" > /dev/null 2>&1
  echo $?
}


# OS based:

function _os_based {
  # Pass function name as first parameter.
  # It will be invoked as os-based function with the postfix.

  case "$(uname -s)" in

    Darwin)
      "$1_osx" "${@:2}"
    ;;

    Linux)
      "$1_linux" "${@:2}"
    ;;

    MINGW*)
      "$1_linux" "${@:2}"
    ;;

    CYGWIN*)
      "$1_linux" "${@:2}"
    ;;

    FreeBSD)
      "$1_freebsd" "${@:2}"
    ;;

    # TODO: add MS Windows support.
    # MINGW32*|MSYS*)
    #   $1_ms ${@:2}
    # ;;

    *)
      _abort 'unsupported OS.'
    ;;
  esac
}


# File System:

function _clean_windows_path {
  # This function transforms windows paths to *nix paths
  # such as  c:\this\that.file -> /c/this/that/file
  # shellcheck disable=SC2001
  echo "$1" | sed 's#^\([a-zA-Z]\):/#/\1/#'
}


function _set_config {
  # This function creates a line in the config, or alters it.

  local key="$1" # required
  local value="$2" # required
  local filename="$3" # required

  # The exit status is 0 (true) if the name was found, 1 (false) if not:
  local contains
  contains=$(grep -Fq "$key" "$filename"; echo "$?")

  # Append or alter?
  if [[ "$contains" -eq 0 ]]; then
    _os_based __replace_in_file "$@"
  elif [[ "$contains" -eq 1 ]]; then
    echo "${key} = ${value}" >> "$filename"
  fi
}


# this sets the global variable 'temporary_filename'
# currently this function is only used by 'hide'
function _temporary_file {
  # This function creates temporary file
  # which will be removed on system exit.
  temporary_filename=$(_os_based __temp_file)  # is not `local` on purpose.

  trap 'if [[ -f "$temporary_filename" ]]; then if [[ -n "$_SECRETS_VERBOSE" ]] || [[ -n "$SECRETS_TEST_VERBOSE" ]]; then echo "git-secret: cleaning up: $temporary_filename"; fi; rm -f "$temporary_filename"; fi;' EXIT
}


# Helper function


function _gawk_inplace {
  local parms="$*"
  local dest_file
  dest_file="$(echo "$parms" | gawk -v RS="'" -v FS="'" 'END{ gsub(/^\s+/,""); print $1 }')"

  _temporary_file

  bash -c "gawk ${parms}" > "$temporary_filename"
  mv "$temporary_filename" "$dest_file"
}


# File System Database (fsdb):


function _get_record_filename {
  # Returns 1st field from passed record
  local record="$1"
  local filename
  filename=$(echo "$record" | awk -F: '{print $1}')

  echo "$filename"
}


function _get_record_hash {
  # Returns 2nd field from passed record
  local record="$1"
  local hash
  hash=$(echo "$record" | awk -F: '{print $2}')

  echo "$hash"
}


function _fsdb_has_record {
  # First parameter is the key
  # Second is the fsdb
  local key="$1"  # required
  local fsdb="$2" # required

  # 0 on contains, 1 for error.
  gawk -v key="$key" "$AWK_FSDB_HAS_RECORD" "$fsdb"
}


function _fsdb_rm_record {
  # First parameter is the key (filename)
  # Second is the path to fsdb
  local key="$1"  # required
  local fsdb="$2" # required

  _gawk_inplace -v key="'$key'" "'$AWK_FSDB_RM_RECORD'" "$fsdb"
}


function _fsdb_clear_hashes {
  # First parameter is the path to fsdb
  local fsdb="$1" # required

  _gawk_inplace "'$AWK_FSDB_CLEAR_HASHES'" "$fsdb"
}


# Manuals:


function _show_manual_for {
  local function_name="$1" # required

  man "git-secret-${function_name}"
  exit 0
}


# Invalid options

function _invalid_option_for {
  local function_name="$1" # required

  man "git-secret-${function_name}"
  exit 1
}


# VCS:


function _check_ignore {
  local filename="$1" # required

  local result
  result="$(git check-ignore -q "$filename"; echo $?)"
  # returns 1 when not ignored, and 0 when ignored
  echo "$result"
}


function _git_normalize_filename {
  local filename="$1" # required

  local result
  result=$(git ls-files --full-name -o "$filename")
  echo "$result"
}


function _maybe_create_gitignore {
  # This function creates '.gitignore' if it was missing.

  local full_path
  full_path=$(_append_root_path '.gitignore')

  if [[ ! -f "$full_path" ]]; then
    touch "$full_path"
  fi
}


function _add_ignored_file {
  # This function adds a line with the filename into the '.gitignore' file.
  # It also creates '.gitignore' if it's not there

  local filename="$1" # required

  _maybe_create_gitignore

  local full_path
  full_path=$(_append_root_path '.gitignore')

  printf '%q\n' "$filename" >> "$full_path"
}


function _is_inside_git_tree {
  # Checks if we are working inside the `git` tree.
  local result
  result=$(git rev-parse --is-inside-work-tree > /dev/null 2>&1; echo $?)

  echo "$result"
}


function _is_tracked_in_git {
  local filename="$1" # required
  local result
  result="$(git ls-files --error-unmatch "$filename" >/dev/null 2>&1; echo $?)"

  if [[ "$result" -eq 0 ]]; then
    echo "1"
  else
    echo "0"
  fi
}


# This can give unexpected .git dir when used in a _subdirectory_
# of another git repo; See #431 and #433.
function _get_git_root_path {
  # We need this function to get the location of the `.git` folder,
  # since `.gitsecret` (or value set by SECRETS_DIR env var)
  # must be in the same dir.

  local result
  result=$(_clean_windows_path "$(git rev-parse --show-toplevel)")
  echo "$result"
}


# Relative paths:

function _append_root_path {
  # This function adds root path to any other path.

  local path="$1" # required

  local root_path
  root_path=$(_get_git_root_path)

  echo "$root_path/$path"
}


function _get_secrets_dir {
  _append_root_path "${_SECRETS_DIR}"
}


function _get_secrets_dir_keys {
  _append_root_path "${_SECRETS_DIR_KEYS}"
}


function _get_secrets_dir_path {
  _append_root_path "${_SECRETS_DIR_PATHS}"
}


function _get_secrets_dir_keys_trustdb {
  _append_root_path "${_SECRETS_DIR_KEYS_TRUSTDB}"
}


function _get_secrets_dir_paths_mapping {
  _append_root_path "${_SECRETS_DIR_PATHS_MAPPING}"
}


# Logic:

function _message {
  local message="$1" # required
  echo "git-secret: $message"
}


function _abort {
  local message="$1" # required
  local exit_code=${2:-"1"}     # defaults to 1

  >&2 echo "git-secret: abort: $message"
  exit "$exit_code"
}


# _warn() sends warnings to stdout so user sees them
function _warn {
  local message="$1" # required

  >&2 echo "git-secret: warning: $message"
}


# _warn_or_abort "$error_message" "$exit_code" "$error_ok"
function _warn_or_abort {
  local message="$1"            # required
  local exit_code=${2:-"1"}     # defaults to 1
  local error_ok=${3:-0}        # can be 0 or 1

  if [[ "$error_ok" -eq "0" ]]; then
    if [[ "$exit_code" -eq "0" ]]; then
      # if caller sends an exit_code of 0, we change it to 1 before aborting.
      exit_code=1
    fi
    _abort "$message" "$exit_code"
  else
    _warn "$message" "$exit_code"
  fi
}


function _find_and_clean {
  # required:
  local pattern="$1" # can be any string pattern

  local verbose_opt=''
  if [[ -n "$_SECRETS_VERBOSE" ]]; then
    verbose_opt='v';
  fi

  local root
  root=$(_get_git_root_path)

  # shellcheck disable=2086
  find "$root" -path "$pattern" -type f -print0 | xargs -0 rm -f$verbose_opt
}


function _find_and_clean_formatted {
  # required:
  local pattern="$1" # can be any string pattern

  local outputs
  outputs=$(_find_and_clean "$pattern")

  if [[ -n "$_SECRETS_VERBOSE" ]] && [[ -n "$outputs" ]]; then
    # shellcheck disable=SC2001
    echo "$outputs" | sed "s/^/git-secret: cleaning: /"
  fi
}


# this sets the global array variable 'filenames'
function _list_all_added_files {
  local path_mappings
  path_mappings=$(_get_secrets_dir_paths_mapping)

  if [[ ! -s "$path_mappings" ]]; then
    _abort "$path_mappings is missing."
  fi

  local filename
  filenames=()      # not local
  while read -r line; do
    filename=$(_get_record_filename "$line")
    filenames+=("$filename")
  done < "$path_mappings"

  declare -a filenames     # so caller can get list from filenames array
}


function _secrets_dir_exists {
  # This function checks if "$_SECRETS_DIR" exists and.

  local full_path
  full_path=$(_get_secrets_dir)

  if [[ ! -d "$full_path" ]]; then
    local name
    name=$(basename "$full_path")
    _abort "directory '$name' does not exist. Use 'git secret init' to initialize git-secret"
  fi
}


function _secrets_dir_is_not_ignored {
  # This function checks that "$_SECRETS_DIR" is not ignored.

  local git_secret_dir
  git_secret_dir=$(_get_secrets_dir)

  local ignores
  ignores=$(_check_ignore "$git_secret_dir")

  if [[ ! $ignores -eq 1 ]]; then
    _abort "'$git_secret_dir' is in .gitignore"
  fi
}


function _exe_is_busybox {
  local exe
  exe="$1"

  # we assume stat is from busybox if it's a symlink
  local is_busybox=0
  local stat_path
  stat_path=$(command -v "$exe")
  if [ -L "$stat_path" ]; then
    is_busybox=1
  fi
  echo "$is_busybox"
}

function _import_exported_keyring {
  local secrets_dir_keys
  secrets_dir_keys=$(_get_secrets_dir_keys)

  if [[ -e "$secrets_dir_keys/exported_keyring.gpg" ]]; then
    # Try to import keys from ASCII representation
    local args=( --homedir "$secrets_dir_keys" --no-permission-warning --import "$secrets_dir_keys/exported_keyring.gpg" )
    if [[ -z "$_SECRETS_VERBOSE" ]]; then
      $SECRETS_GPG_COMMAND "${args[@]}" > /dev/null 2>&1 3>&-
    else
      $SECRETS_GPG_COMMAND "${args[@]}" 3>&-
    fi
    local exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
      _abort "problem importing ASCII keyring with gpg: exit code $exit_code"
    fi
  fi
}

# this is used by just about every command
function _user_required {
  # This function does a bunch of validations:
  # 1. It calls `_secrets_dir_exists` to verify that "$_SECRETS_DIR" exists.
  # 2. It ensures that "$_SECRETS_DIR_KEYS_TRUSTDB" exists.
  # 3. It ensures that there are added public keys.

  _secrets_dir_exists

  local trustdb
  trustdb=$(_get_secrets_dir_keys_trustdb)

  local error_message="no public keys for users found. run 'git secret tell email@address'."
  if [[ ! -f "$trustdb" ]]; then
    _abort "$error_message"
  fi

  local secrets_dir_keys
  secrets_dir_keys=$(_get_secrets_dir_keys)

  # see https://github.com/bats-core/bats-core#file-descriptor-3-read-this-if-bats-hangs for info about 3>&-
  local keys_exist
  keys_exist=$($SECRETS_GPG_COMMAND --homedir "$secrets_dir_keys" --no-permission-warning -n --list-keys 3>&-)
  local exit_code=$?
  if [[ -z "$keys_exist" && -e "$secrets_dir_keys/exported_keyring.gpg" ]]; then
    _import_exported_keyring

    keys_exist=$($SECRETS_GPG_COMMAND --homedir "$secrets_dir_keys" --no-permission-warning -n --list-keys 3>&-)
    exit_code=$?
  fi
  if [[ -z "$keys_exist" ]]; then
    _abort "$error_message"
  fi
  if [[ "$exit_code" -ne 0 ]]; then
    # this might catch corner case where gpg --list-keys shows
    # 'gpg: skipped packet of type 12 in keybox' warnings but succeeds?
    # See #136
    echo "$keys_exist"	# show whatever _did_ come out of gpg
    _abort "problem listing public keys with gpg: exit code $exit_code"
  fi
}


# note: this has the same 'username matching' issue described in
# https://github.com/sobolevn/git-secret/issues/268
# where it will match emails that have other emails as substrings.
# we need to use fingerprints for a unique key id with gpg.
function _get_user_key_expiry {
  # This function returns the user's key's expiry, as an epoch.
  # It will return the empty string
  # if there is no expiry date for the user's key
  local username="$1"
  local line

  local secrets_dir_keys
  secrets_dir_keys=$(_get_secrets_dir_keys)

  # 3>&- closes fd 3 for bats, see https://github.com/bats-core/bats-core#file-descriptor-3-read-this-if-bats-hangs
  line=$($SECRETS_GPG_COMMAND --homedir "$secrets_dir_keys" --no-permission-warning --list-public-keys --with-colon --fixed-list-mode "$username" | grep ^pub: 3>&-)

  local expiry_epoch
  expiry_epoch=$(echo "$line" | cut -d: -f7)
  echo "$expiry_epoch"
}


function _assert_keyring_contains_emails {
  local homedir="$1"
  local keyring_name="$2"
  local emails="$3"

  # 1 here means 'expect $emails in keyring':
  _assert_keyring_emails "$homedir" "$keyring_name" "$emails" 1
}


function _assert_keyring_doesnt_contain_emails {
  local homedir="$1"
  local keyring_name="$2"
  local emails="$3"

  # 0 here means 'don't expect $emails in keyring':
  _assert_keyring_emails "$homedir" "$keyring_name" "$emails" 0
}


function _assert_keyring_emails {
  local homedir="$1"
  local keyring_name="$2"
  local emails="$3"
  # set this to:
  # 0 to not expect the email in the keyring;
  # 1 to expect the email in the keyring
  local expected="$4"

  local gpg_uids
  gpg_uids=$(_get_users_in_gpg_keyring "$homedir")
  for email in "${emails[@]}"; do
    if [[ $email != *"@"* ]]; then
      _abort "does not appear to be an email: $email"
    fi
    local emails_found=0
    for uid in $gpg_uids; do
      if [[ "$uid" == "$email" ]]; then
        emails_found=$((emails_found+1))
      fi
    done
    if [[ $expected -eq 1 ]]; then
        if [[ $emails_found -eq 0 ]]; then
          _abort "no key found in gpg $keyring_name for: $email"
        elif [[ $emails_found -gt 1 ]]; then
          _abort "$emails_found keys found in gpg $keyring_name for: $email"
        fi
    else
        if [[ $emails_found -gt 0 ]]; then
          _abort "$emails_found keys found in gpg $keyring_name for: $email"
        fi
    fi

  done
}


function _get_encrypted_filename {
  local filename
  filename="$(dirname "$1")/$(basename "$1" "$SECRETS_EXTENSION")"
  echo "${filename}${SECRETS_EXTENSION}" | sed -e 's#^\./##'
}


# this is used throughout this file, and in 'whoknows'
function _get_users_in_gpg_keyring {
  # show the users in the gpg keyring.
  # `whoknows` command uses it internally.
  # parses the `gpg` public keys
  local homedir=$1
  local result
  local args=()
  if [[ -n "$homedir" ]]; then
    args+=( "--homedir" "$homedir" )
  fi

  ## We use --fixed-list-mode so older versions of gpg emit 'uid:' lines.
  ## Gawk splits on colon as --with-colon, matches field 1 as 'uid',
  result=$($SECRETS_GPG_COMMAND "${args[@]}" --no-permission-warning --list-public-keys --with-colon --fixed-list-mode | \
      gawk -F: '$1=="uid"' )

  # For #508 / #552: warn user if gpg indicates keys are one of:
  # i=invalid, d=disabled, r=revoked, e=expired, n=not valid
  # See https://github.com/gpg/gnupg/blob/master/doc/DETAILS#field-2---validity # for more on gpg 'validity codes'.
  local invalid_lines
  invalid_lines=$(echo "$result" | gawk -F: '$2=="i" || $2=="d" || $2=="r" || $2=="e" || $2=="n"')

  local emails
  emails=$(_extract_emails_from_gpg_output "$result")

  local emails_with_invalid_keys
  emails_with_invalid_keys=$(_extract_emails_from_gpg_output "$invalid_lines")

  if [[ -n "$emails_with_invalid_keys" ]]; then
     _warn "at least one key for email(s) is revoked, expired, or otherwise invalid: $emails_with_invalid_keys"
  fi

  echo "$emails"
}


function _extract_emails_from_gpg_output {
  local result=$1

  # gensub() outputs email from <> within field 10, "User-ID".  If there's no <>, then field is just an email address
  #  (and maybe a comment) and we pass it through.
  # Sed at the end removes any 'comment' that appears in parentheses, for #530
  # 3>&- closes fd 3 for bats, see https://github.com/bats-core/bats-core#file-descriptor-3-read-this-if-bats-hangs
  local emails
  emails=$(echo "$result" | gawk -F: '{print gensub(/.*<(.*)>.*/, "\\1", "g", $10); }' | sed 's/([^)]*)//g' 3>&-)
  echo "$emails"
}


function _get_users_in_gitsecret_keyring {
  # show the users in the gitsecret keyring.
  local secrets_dir_keys
  secrets_dir_keys=$(_get_secrets_dir_keys)

  local result
  result=$(_get_users_in_gpg_keyring "$secrets_dir_keys")

  echo "$result"
}


function _get_recipients {
  # This function is required to create an encrypted file for different users.
  # These users are called 'recipients' in the `gpg` terms.
  # It basically just parses the `gpg` public keys

  local result
  # put -r before each user:
  result=$(_get_users_in_gitsecret_keyring | sed 's/^/-r/')
  echo "$result"
}


function _decrypt {
  # required:
  local filename="$1"

  # optional:
  local write_to_file=${2:-1} # can be 0 or 1
  local force=${3:-0} # can be 0 or 1
  local homedir=${4:-""}
  local passphrase=${5:-""}
  local error_ok=${6:-0} # can be 0 or 1

  local encrypted_filename
  encrypted_filename=$(_get_encrypted_filename "$filename")

  local args=( "--use-agent" "--decrypt" "--no-permission-warning" )

  if [[ "$write_to_file" -eq 1 ]]; then
    args+=( "-o" "$filename" )
  fi

  if [[ "$force" -eq 1 ]]; then
    args+=( "--yes" )
  fi

  if [[ -n "$homedir" ]]; then
    args+=( "--homedir" "$homedir" )
  fi

  if [[ "$GPG_VER_MIN_21" -eq 1 ]]; then
    if [[ -n "$SECRETS_PINENTRY" ]]; then
      args+=( "--pinentry-mode" "$SECRETS_PINENTRY" )
    else
      args+=( "--pinentry-mode" "loopback" )
    fi
  fi

  if [[ -z "$_SECRETS_VERBOSE" ]]; then
    args+=( "--quiet" )
  fi

  set +e   # disable 'set -e' so we can capture exit_code

  #echo "# gpg passphrase: $passphrase" >&3
  local exit_code
  if [[ -n "$passphrase" ]]; then
    echo "$passphrase" | $SECRETS_GPG_COMMAND "${args[@]}" --batch --yes --no-tty --passphrase-fd 0 \
      "$encrypted_filename"
    exit_code=$?
  else
    $SECRETS_GPG_COMMAND "${args[@]}" "$encrypted_filename"
    exit_code=$?
  fi

  set -e  # re-enable set -e

  # note that according to https://github.com/sobolevn/git-secret/issues/238 ,
  # it's possible for gpg to return a 0 exit code but not have decrypted the file
  #echo "# gpg exit code: $exit_code, error_ok: $error_ok" >&3
  if [[ "$exit_code" -ne "0" ]]; then
    local msg="problem decrypting file with gpg: exit code $exit_code: $filename"
    _warn_or_abort "$msg" "$exit_code" "$error_ok"
  fi

  # at this point the file should be written to disk or output to stdout
}
