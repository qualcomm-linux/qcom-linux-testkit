# Detect Android userland
ANDROID_PATH=/system/build.prop
if [ -f $ANDROID_PATH ]; then
    ANDROID=1
    SHELL_CMD=sh
else
    ANDROID=0
    SHELL_CMD=bash
fi

function pidkiller()
{
  if [ $ANDROID -eq 0 ]; then
    disown $1
  fi
  kill -9 $1 >/dev/null 2>&1
}
