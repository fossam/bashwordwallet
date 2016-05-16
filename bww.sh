#!/bin/bash -u

#SET THE FOLLOWING VARIABLE
#path to encrypted file that stores information
ENCRYPTED_FILE=storepass.enc.current
INPUTTIMEOUT=300

#in case of writing files create them with limited permissions
builtin umask 0177

#no need to depend on anything else
PATH=/usr/bin:/bin

set +o history
set -E

function errorout {
#error messages should go to sterr, and to eliminate redirect and exit syntax pollution
#often exit is needed after an error message, accept optional second parameter as exit code
#this function takes one or two arguments depending on usage
#usage: errorout "message" <exit_code>
#if exit code is specified, then the script will exit returning the exit code.
  echo "$1" >&2
  if ! [ -z "${2-}" ] ; then
    exit $2
  fi
}

#incase sensitive information is on the screen in an unsuitable environment ctrl-c clears the screen and exits
#the script should also notify the user if it exits for other reasons
trap 'clear; errorout "Received user interrupt or a another signal from system. The script will exit." 1' INT TERM HUP QUIT KILL

#TODO: implement workarounds on rhel 5 base with ye olde versions
#if too old, exit very early. bash 3.2 does not have readarray
if (( ${BASH_VERSINFO[0]} < 4 )) ; then
  echo "The script needs Bash version 4 or higher."
  exit 1
fi

function usage {
  cat <<-HERE
Usage: $0 add       # interactively add lines to the file
   or: $0 delete    # interactively delete lines based on search criteria
Due to sensitive information, the queries need to be entered interactively.
Please don't include any queries from the shell command line prompt.
You will be also asked for the encryption passphrase for the file.
HERE
}

#no argument given, exit early
if [ -z "${1-}" ] ; then
  usage
  exit 0
fi

#if path has local or non absolute path elements then exit
function checkpaths {
  local path
  for path in $@; do
    if [[ $path =~ /\.\.$ || $path =~ ^\.\./ || $path =~ /\.\./ || $path =~ ^\.\.$ ]] ; then
      errorout "Attempted use of sneaky paths. The script will exit." 1
    fi
  done
}

#get the colons out of the path variable before checking
checkpaths $(echo "${PATH//:/\ }")

#make sure the environment is aware of required binaries
REQUIRED_BINARIES="openssl grep sed cat tr cut"
for BINARY in $REQUIRED_BINARIES; do
  if ! which -b $BINARY > /dev/null 2>/dev/null; then
    errorout "$BINARY is not found on this environment." 1
  fi
done

function askuser {
  #this function requires two or three arguments depending on usage
  #usage: askuser "prompt" variable_name silent
  #if something is specified in the silent field, user input is not echoed back
  builtin read -t "$INPUTTIMEOUT" ${3+-s} -p "$1" "$2" ||
    errorout "No input received in 5 minutes. The script will exit." 1
  echo
}

function openssladd {
  #sensitive info handled from here on out.
  "$NEWFILE" || echo "Current contents of "${ENCRYPTED_FILE##*/}":"
  for COUNTER in 1 2 3 ; do
    askuser "Please enter the passphrase for the file: " FILEPASS silent
    "$NEWFILE" && {
      askuser "Please verify the passphrase: " VERIFYPASS silent
      if [ "$FILEPASS" != "$VERIFYPASS" ] ; then
        errorout "The passphrases don't match."
        continue
       else
         builtin unset VERIFYPASS
      fi
       }
    set --
    exec 6<<<"$FILEPASS"
    "$NEWFILE" ||
      openssl aes-256-cbc -d -in $ENCRYPTED_FILE -pass fd:6 2>/dev/null | grep -I "${2-}" 2>/dev/null
      RETURNSTATUS=(${PIPESTATUS[@]})
    #check exit status of openssl command. the failure means either bad passphrase or a problem with the file
    if (( "${RETURNSTATUS[0]}" >= 1 )) && ! "$NEWFILE"  ; then
      builtin unset FILEPASS
      errorout "There was a problem with decrypting the file."
      continue
    else
      #passphrase correct, plaintext in stdout
      "$NEWFILE" && echo "The encrypted file will be created until you're finished entering the new lines."
      cat <<-HERE
Enter the lines you want to add. Limited editing features are available, but
only for the current line. Once you press Enter, you can't go back.
An empty line will end the session and the entered lines are appended to the file.
HERE
      #read lines from the user one by one until an empty line is entered
      builtin readarray LINEARRAY < <(while builtin read -e LINE ; do
                                        [ -z "$LINE" ] && break
                                        builtin echo "$LINE"
                                      done
                                     )
      { #decrypted information is sent to pipe, followed by user-entered lines
        #for loop is to avoid sed or printing of the last empty newline TODO: change this situation
       if ! "$NEWFILE" ; then
         BACKUP_ENCRYPTED_FILE="${ENCRYPTED_FILE%current}$(date +%F#%H-%M-%S-$RANDOM)"
         cp  --preserve=mode,ownership "$ENCRYPTED_FILE" "$BACKUP_ENCRYPTED_FILE"
         exec 3<<<"$FILEPASS"
         openssl aes-256-cbc -d -in $BACKUP_ENCRYPTED_FILE -pass fd:3 2>/dev/null
       fi
       for (( c = 0; c < "${#LINEARRAY[@]}" ; c = c + 1 )) ; do
         builtin echo -n "${LINEARRAY[ $c ]}"
       done
      } | {
           if "$NEWFILE" && ! touch "$ENCRYPTED_FILE" ; then
             errorout "Error creating $ENCRYPTED_FILE" 1
           fi
           exec 3<<<"$FILEPASS"
           #openssl accepts text from stdin from pipe, and writes it out to the file
           openssl aes-256-cbc -salt -out $ENCRYPTED_FILE -pass fd:3
           if [ "$?" ] ; then
             echo ""${ENCRYPTED_FILE##*/}" was succesfully modified."
           else
             echo "OpenSSL reported an error while trying to write to "${ENCRYPTED_FILE##*/}". Changes may have been lost."
           fi
           builtin unset FILEPASS
          }
      break
    fi
  done
}

case "$1" in
    add) NEWFILE=false
	      if ! [ -a "$ENCRYPTED_FILE" ] ; then
 	        echo "$ENCRYPTED_FILE does not exist."
	        until [ ! -z "${PCREATE-}" ] ; do
            askuser "Would you like to create one: (yes/[no]) " PCREATE
            case ${PCREATE,,} in
	            yes) echo "$ENCRYPTED_FILE will be created."
                   NEWFILE=true
		            ;;
	             y*) echo "Please use the full word 'yes'."
		               unset PCREATE
		            ;;
		            *) errorout "File not created. The script will exit." 1
	              ;;
	          esac
          done
        fi
	      if $NEWFILE || ( [ -f "$ENCRYPTED_FILE" ] && [ -r "$ENCRYPTED_FILE" ] && [ -w "$ENCRYPTED_FILE" ] ) ; then
	      #add
        openssladd
	      else
          errorout "$ENCRYPTED_FILE must have read and write permissions." 1
        fi
	    ;;
 delete)
        ASKSEARCH=true ; ASKPASS=true
        if ! [ -a "$ENCRYPTED_FILE" ] ; then
          errorout "$ENCRYPTED_FILE does not exist." 1
        fi
        if [ -f "$ENCRYPTED_FILE" ] && [ -r "$ENCRYPTED_FILE" ] && [ -w "$ENCRYPTED_FILE" ] ; then
          for COUNTER in 1 2 3 ; do
            if [[ "${ASKSEARCH-}" ]] ; then
              askuser "Search string or 'all' (confirmed before deleting): " STRING
            fi
            [ -z "${STRING-}" ] && errorout "Nothing entered. The script will exit." 1
            if [[ "${ASKPASS-}" ]] ; then
              askuser "Please enter the passphrase for the file: " FILEPASS silent
            fi
            [ "${STRING,,}" = "all" ] && STRING="${STRING+}"

              exec 3<<<"$FILEPASS"
              builtin readarray LINEARRAY < <( openssl aes-256-cbc -d -in $ENCRYPTED_FILE -pass fd:3 2>/dev/null > >( grep -In "$STRING" 2>/dev/null ) )
              RETURNSTATUS=(${PIPESTATUS[@]})
              #check exit status of openssl. failure means either bad passphrase or a problem with the file
              if (( "${RETURNSTATUS[0]}" >= 1 )) ; then
                errorout "There was a problem with decrypting the file."
                ASKSEARCH=false; ASKPASS=true
                continue
              #check exit status of grep. non-zero if there's either problem with grep or nothing found
              elif (( "${RETURNSTATUS[1]}" >= 1 )) ; then
                errorout "\" $STRING \" was not found in the file." "${RETURNSTATUS[1]}"
                ASKSEARCH=true; ASKPASS=false
                continue
              fi

            #at this point passphrase is correct
            #loop through the grepped openssl output and save lines numbers grep found
              for (( c = 0; c < "${#LINEARRAY[@]}" ; c = c + 1 )) ; do
                LINENUMBER[ $c ]=$( echo ${LINEARRAY[ $c ]} | cut -d':' -f1 )
                builtin echo -n "${LINENUMBER[ $c ]}: $( echo ${LINEARRAY[ $c ]} | cut -d':' -f2 )"
              done
              builtin read -t "$INPUTTIMEOUT" -e -p "Choose line number(s) to delete (separated by space): " LINESTODEL ||
                errorout "No input received in 5 minutes. The script will exit." 1
              #parse,clean,validate
              LINESTODEL=$(echo $LINESTODEL | tr -d "[:alpha:]" | tr -d "[:punct:]" | tr -s " ")
              LINESTODELARRAY=($LINESTODEL)
              echo "The following lines will be deleted:"
              for L in "${LINESTODELARRAY[@]}" ; do
                echo "$L: $( echo ${LINEARRAY[ $L ]} | cut -d':' -f2 )"
              done
              builtin unset LINEARRAY
              until [ ! -z "${DELCONFIRM-}" ] ; do
                askuser "Confirm to delete: (yes/[no]) " DELCONFIRM
                case ${DELCONFIRM,,} in
    	            yes) #delete the actual lines and write the result
    		               #sed commands are derived from the array built from user input
                       SEDCOMMANDS="${LINESTODELARRAY[@]/%/d;}"
                       BACKUP_ENCRYPTED_FILE=${ENCRYPTED_FILE%current}$(date +%F-%H-%M-%S-$RANDOM)
                       cp -p "$ENCRYPTED_FILE" "$BACKUP_ENCRYPTED_FILE"
                       exec 3<<<"$FILEPASS"
                       exec 4<<<"$FILEPASS"
                       openssl aes-256-cbc -d -in $BACKUP_ENCRYPTED_FILE -pass fd:3 2>/dev/null | sed ''"$SEDCOMMANDS"'' | openssl aes-256-cbc -salt -out $ENCRYPTED_FILE -pass fd:4
                       #we need to get out of the until loop and the for loop
                       break 2
    		            ;;
    	             y*) echo "Please use the full word 'yes'."
    		               unset DELCONFIRM
    		            ;;
    		            *) errorout "File not created. The script will exit." 1
    	              ;;
    	          esac
                builtin unset FILEPASS
              done

          done
          builtin unset FILEPASS
        else
          errorout "$ENCRYPTED_FILE must have read and write permissions." 1
        fi
	    ;;
changefilepass*)
      ;&
chfilepw)
      ;&
    cfp)
        #to change passphrase for the file, first the file needs to be decrypted and then encrypted
        #with the new one. this section does basically that.
        if ! [ -a "$ENCRYPTED_FILE" ] ; then
          errorout "$ENCRYPTED_FILE does not exist."
          errorout "\'$0 add\' can be used to create one." 1
        fi
        if [ -f "$ENCRYPTED_FILE" ] && [ -r "$ENCRYPTED_FILE" ] && [ -w "$ENCRYPTED_FILE" ] ; then
          STRING="${STRING+}"
          for COUNTERA in 1 2 3 ; do
            askuser "Please enter the current passphrase for the file: " FILEPASS silent
            exec 3<<<"$FILEPASS"
            openssl aes-256-cbc -d -in $ENCRYPTED_FILE -pass fd:3 2>/dev/null | grep -In "$STRING" 2>/dev/null >/dev/null
            RETURNSTATUS=(${PIPESTATUS[@]})
            #check exit status of openssl. failure means either bad passphrase or a problem with the file
            if (( "${RETURNSTATUS[0]}" >= 1 )) ; then
              errorout "There was a problem with decrypting the file."
              continue
            else
              #five chances to get long enough passphrase and make sure they match
              for COUNTERB in 1 2 3 4 5 ; do
                askuser "Please enter the new passphrase: " NEWPASS silent
                if [ -z "${NEWPASS}" ] ; then
                  errorout "This passphrase is a bit short. Recommended length is around 5 or more words that should have at least 15 or more characters combined."
                  continue
                else
                  askuser "Please verify the new passphrase: " VERIFYPASS silent
                  if [ "$NEWPASS" != "$VERIFYPASS" ] ; then
                    errorout "The passphrases don't match."
                    continue
                  else
                    builtin unset VERIFYPASS
                    #make a backup and save the new file
                    BACKUP_ENCRYPTED_FILE=${ENCRYPTED_FILE%current}$(date +%F-%H-%M-%S-$RANDOM)
                    cp -p "$ENCRYPTED_FILE" "$BACKUP_ENCRYPTED_FILE" && {
                       exec 3<<<"$FILEPASS"
                       exec 4<<<"$NEWPASS"
                       openssl aes-256-cbc -d -in $BACKUP_ENCRYPTED_FILE -pass fd:3 2>/dev/null | openssl aes-256-cbc -salt -out $ENCRYPTED_FILE -pass fd:4
                       builtin unset FILEPASS
                       builtin unset NEWPASS
                     } && {
                       echo "New passphrase has been set. Please remember it."
                       #both for loops need to be exited
                       break 2
                     }
                  fi
                fi
              done
              builtin unset NEWPASS
              builtin unset VERIFYPASS
              errorout "Failed to meet new passphrase requirements after five tries. The script will exit." 1
              break
            fi
          done
          builtin unset FILEPASS
        else
          errorout "$ENCRYPTED_FILE must have read and write permissions." 1
        fi
      ;;
      *)
        usage
        exit 0
      ;;
esac
