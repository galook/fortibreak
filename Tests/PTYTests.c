#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
extern int fb_spawn(char *const[], int *);
extern int fb_wait(int, int *);
extern void fb_signal(int, int);
int main(void) {
    char *argv[]={"/bin/sh", "-c", "printf 'Account password: '; read -r secret; printf '\\naccepted\\n'; sleep 30", NULL};
    int master=-1, code=-1, pid=fb_spawn(argv,&master);
    if(pid<=0) return 1;
    char output[4096]={0}; size_t used=0;
    for(int i=0;i<20 && !strstr(output,"Account password:");i++) {
        struct pollfd p={master,POLLIN,0};
        if(poll(&p,1,100)>0) { int n=read(master,output+used,sizeof(output)-used-1); if(n>0) used+=n; }
    }
    if(!strstr(output,"Account password:")) {fb_signal(pid,SIGKILL);return 2;}
    const char *secret="test-private-value\n";write(master,secret,strlen(secret));
    for(int i=0;i<20 && !strstr(output,"accepted");i++) {
        struct pollfd p={master,POLLIN,0};
        if(poll(&p,1,100)>0) {int n=read(master,output+used,sizeof(output)-used-1); if(n>0) used+=n;}
    }
    int ok=strstr(output,"accepted") && !strstr(output,"test-private-value");
    fb_signal(pid,SIGINT);
    int ended=0;for(int i=0;i<30;i++){if(fb_wait(pid,&code)){ended=1;break;}usleep(100000);}
    if(!ended) {fb_signal(pid,SIGKILL);usleep(100000);fb_wait(pid,&code);}
    close(master);
    if(!ok || !ended) return 3;
    puts("Passed PTY password, no-echo and process-group stop checks. Local fixture only.");
    return 0;
}
