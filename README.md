# Santek EZ Door Sign Uploader
> All completely in bash, coreutils, and ImageMagick
---

This is a bash implementation of the Santek EZ Door Sign uploader utility.

For more information on the EZ Door Sign protocol, read my write-up at https://leo.leung.xyz/wiki/Santek_EZ_Door_Sign

# Usage
`screen.sh` has 3 operations that you can run.


## ping
Ping keeps the serial connection to the display alive (as it times out after about 5 or so minutes).
```
bash screen.sh ping
```

## slide
Changes the slide to one of 5 pre-programmed slides.
```
bash screen.sh slide [0-4]
```

## upload
Uploads an image to one of the 5 slide slots. This script depends on ImageMagick to convert to a bitmap file.

```
bash screen.sh upload 0 canada.png
```


# But why Bash??
This was implmented only because I wanted to update one of the door signs from an OpenWRT router near by.

