chgrp -R 0 "$1"
chmod -R g+rw "$1"
find "$1" -type d -exec chmod g+x {} +
