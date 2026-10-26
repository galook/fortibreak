#include <util.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <termios.h>
#include <stdlib.h>
#include <errno.h>

int cg_spawn(char *const argv[], int *master) {
    struct termios tty;
    int pid = forkpty(master, NULL, NULL, NULL);
    if (pid == 0) {
        if (tcgetattr(STDIN_FILENO, &tty) == 0) {
            tty.c_lflag &= ~(ECHO | ECHONL);
            tcsetattr(STDIN_FILENO, TCSANOW, &tty);
        }
        char *environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/var/root", "LC_ALL=C", "OPENSSL_CONF=/dev/null",
#ifdef CG_PRIVILEGED_RUNTIME
            "SSL_CERT_FILE=/Library/PrivilegedHelperTools/eu.local.cleargate/cert.pem",
            "OPENSSL_MODULES=/Library/PrivilegedHelperTools/eu.local.cleargate/modules",
#endif
            NULL};
        execve(argv[0], argv, environment);
        _exit(127);
    }
    return pid;
}
int cg_wait(int pid, int *exitcode) {
    int status = 0;
    int result = waitpid(pid, &status, WNOHANG);
    if (result == pid) {
        *exitcode = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
        return 1;
    }
    return result == -1 && errno == ECHILD ? 1 : 0;
}
void cg_signal(int pid, int sig) { if (pid > 1) kill(-pid, sig); }
// Ask the engine to restore routes before it closes its PPP child. Signalling
// the entire group immediately can tear PPP down while restoration is running.
void cg_signal_engine(int pid, int sig) { if (pid > 1) kill(pid, sig); }
