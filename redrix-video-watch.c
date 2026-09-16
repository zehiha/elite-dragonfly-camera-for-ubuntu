#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s /dev/videoN\n", argv[0]);
        return 2;
    }

    int fd = inotify_init1(IN_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "inotify_init1: %s\n", strerror(errno));
        return 1;
    }

    uint32_t mask = IN_OPEN | IN_CLOSE_WRITE | IN_CLOSE_NOWRITE | IN_ATTRIB |
                    IN_DELETE_SELF | IN_MOVE_SELF;
    int wd = inotify_add_watch(fd, argv[1], mask);
    if (wd < 0) {
        fprintf(stderr, "inotify_add_watch %s: %s\n", argv[1], strerror(errno));
        close(fd);
        return 1;
    }

    char buf[sizeof(struct inotify_event) + NAME_MAX + 1];
    for (;;) {
        ssize_t len = read(fd, buf, sizeof(buf));
        if (len < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "read: %s\n", strerror(errno));
            break;
        }

        for (char *ptr = buf; ptr < buf + len; ) {
            struct inotify_event *event = (struct inotify_event *)ptr;

            if (event->mask & IN_OPEN)
                puts("open");
            if (event->mask & (IN_CLOSE_WRITE | IN_CLOSE_NOWRITE))
                puts("close");
            if (event->mask & (IN_DELETE_SELF | IN_MOVE_SELF)) {
                puts("gone");
                fflush(stdout);
                close(fd);
                return 0;
            }

            fflush(stdout);
            ptr += sizeof(struct inotify_event) + event->len;
        }
    }

    close(fd);
    return 1;
}
