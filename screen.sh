#!/bin/bash

# Set the serial port (modify as needed)
SERIAL_PORT="/dev/ttyACM0"

PIDFILE="/tmp/screen.pid"

if [ ! -c $SERIAL_PORT ] ; then
        if [ -f $SERIAL_PORT ] ; then
                rm $SERIAL_PORT
        fi
        rmmod cdc_acm
        modprobe cdc_acm
fi

# Check if the PID file exists
if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    if kill -0 $PID 2>/dev/null; then
        echo "Script is already running with PID $PID. Exiting."
        exit 1
    else
        echo "Stale PID file found. Removing and starting fresh."
        rm -f "$PIDFILE"
    fi
fi

# Write the current script's PID to the file
echo $$ > "$PIDFILE"

# Trap to remove PID file on exit
trap "rm -f $PIDFILE" EXIT


# Configure the serial port settings
stty -F "$SERIAL_PORT" 9600 raw -echo -parenb -cstopb


# Function to send command with checksum calculation
send_command() {
	local command="$1"
	local data="$2"
	local expect_reply="${3:-0}"
	local length=$(( ${#data} / 4 ))
	local sum=0
	local byte

	# Prepend data length before data
    LengthHex=$(printf "\\\x%02x" $length)
	local payload="$command$LengthHex$data"

	# Calculate checksum (sum of payload bytes mod 256)
	for ((i=0; i<${#payload}; i+=4)); do
		byte="0x${payload:i+2:2}"
		sum=$(( (sum + byte) % 256 ))
	done

	# Convert checksum to hex
	ChecksumHex=$(printf "\\\x%02x" $sum)

	# Write the binary data to the serial port
	echo -ne "\xbb\x00$payload$ChecksumHex\x7e" > "$SERIAL_PORT"

	# Expect 7 bytes back as ack.
	if [ $expect_reply -gt 0 ] ; then
		# echo -n "Wait for ack: "
		timeout 2 head -c $expect_reply "$SERIAL_PORT" | timeout 3 od -An -tx1 -w128
	fi
}


function redraw() {
	Slide="$1"

	if [ $Slide -lt 0 ] || [ $Slide -gt 4 ] ; then
		echo "Error: Slide $Slide is invaild. Must be between 0 and 4."
		exit 1
	fi

	# redraw slide X
	Return=$(echo $(send_command "\x00" "\x0$1" 7))
	if [[ "$Return" == "bb 01 00 01 0$Slide 0$((Slide+2)) 7e" ]] ; then
		echo "Changed to slide $Slide"
	else
		echo "Error: command failed with $Return"
	fi

}


function read_bitmap() {
	Slide=1
	Canvas=0

	# Iterate over canvas (0 or 1)
	for c in {0..1} ; do
		# Iterate over column
		for x in {0..295} ; do
			ColHigh=$(printf "\\\x%02x" $((x / 256)))
			ColLow=$(printf "\\\x%02x" $((x % 256)))

			# Get bitmap data (0x05), ask for: site (1) - canvas (1) - col (2)  - total 4 bytes
			send_command "\x05" "\x0$Slide\x0$Canvas$ColHigh$ColLow" 24
		done
	done
}

function upload_image() {
	Slide="${1:-1}"
	Image="$2"

	if [ ! -f "$Image" ] ; then
		echo "Error: $Image not found."
		exit 1
	fi

	if [ $Slide -lt 0 ] || [ $Slide -gt 4 ] ; then
		echo "Error: Slide $Slide is invaild. Must be between 0 and 4."
		exit 1
	fi

	echo "Processing image..."

	# Image magick to convert picture into parsable format
	# File will contain:  x,y canvas-0 canvas-1
	convert "$Image" \
		-fuzz 33% -fill red -opaque '#ff0000' \
		-fuzz 50% -fill black -opaque '#000000' \
		-fuzz 33% -fill white -opaque '#ffffff' txt: 2>/dev/null \
		| tr : ' ' \
		| grep -vE '^#' \
		| while read i _ _ k ; do
			case "$k" in
				"black") echo $i 0 0 ;;
				"white") echo $i 1 0 ;;
				"red")   echo $i 0 1 ;;
				*)       echo $i 0 0 ;;
			esac
		done \
		> /tmp/x

	# Expect to have 37888 lines, exactly (from 296x128)
	if [ $(wc -l < /tmp/x) -ne 37888 ] ; then
		echo "Error: Invalid image size."
		rm /tmp/x
		exit 1
	fi

	echo "Uploading image..."

	# Iterate over both canvases (0 or 1)
	for c in {0..1} ; do
		# Send image head data, specifying the slide # and canvas
		Return=$(echo $(send_command "\x03" "\x0$Slide\x0$c" 7))
			if [[ "$Return" != "bb 01 03 01 01 06 7e" ]] ; then
				echo "write failure"
			fi

		# Iterate over each column in the picture.
		for x in {0..295} ; do
			ColHigh=$(printf "\\\x%02x" $((x / 256)))
			ColLow=$(printf "\\\x%02x" $((x % 256)))
			
			# Get the bitmap data for each column. We have 2 canvas to iterate over. (although, for black and white pictures, can we just do canvas 0)
			BitmapData=""
			if [ $c -eq 0 ] ; then
				# First canvas
				BitmapData=$(cat /tmp/x | grep -E "^$x," | while read xy canvas0 canvas1; do echo -n $canvas0 ; done)
			else
				# Second canvas
				BitmapData=$(cat /tmp/x | grep -E "^$x," | while read xy canvas0 canvas1; do echo -n $canvas1 ; done)
			fi

			# Expect 128 length. split to four 4-byte chunks to avoid issues...
			BitmapHex=$(
				(
					printf "%08X" $((2#${BitmapData:0:32}))
					printf "%08X" $((2#${BitmapData:32:32}))
					printf "%08X" $((2#${BitmapData:64:32}))
					printf "%08X" $((2#${BitmapData:96:32}))
				) \
				| sed 's/\(..\)/\\x\1/g' )
			# Expect 7 bytes back: bb 01 04 01 01 07 7e
			Return=$(echo $(send_command "\x04" "$ColHigh$ColLow$BitmapHex" 7))
			if [[ "$Return" != "bb 01 04 01 01 07 7e" ]] ; then
				echo "write failure"
			else
				[ $((x % 10)) -eq 0 ] && echo -n "."
			fi
		done
	done

	redraw $Slide
}

function check_is_blank() {
	# check what the status of the given slide is
	echo $(send_command "\x01" "\x0$1" 7)
}

function wait_until_ready() {
	while true ; do
		Return=$(check_is_blank 0)
		if [[ "${Return:0:12}" == "bb 01 01 01 " ]]; then
			break
		fi

		echo "waiting for device..."
		sleep 1
	done
}

if [[ "$1" == "ping" ]] ; then
	# It might take a couple tries if the serial buffer has garbage
	for i in {1..5} ; do
		Return=$(check_is_blank 0)
		if [[ "${Return:0:12}" == "bb 01 01 01 " ]]; then
			echo ok
			exit 0
		fi
	done

	echo "Error: Please power on the display and try again."
	echo "   got back: $Return"
	exit 1
fi

if [[ "$1" == "upload" ]] ; then
	wait_until_ready
	upload_image $2 $3
fi


if [[ "$1" == "slide" ]] ; then
	wait_until_ready
	redraw $2
fi
