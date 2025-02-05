/*
 * comm.h
 *
 *      Author: aagapi
 */

#ifndef BACKEND_COMM_H_
#define BACKEND_COMM_H_

#include "failure_detector/db_queries.h"
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <arpa/inet.h>
#include <string.h>
#include <sys/time.h>
#include <sys/select.h>
#include <netdb.h>

#define VERBOSE_RPC 0
#define COMM_VERBOSITY 2

#define BUFSIZE 128 * 1024
#define MAX_CONNECT_RETRIES 5

#define NODE_LIVE 0
#define NODE_DEAD 1
#define NODE_UNKNOWN 2
#define NODE_PREJOINED 3

// Comm loop fctns:

int parse_message(void * rcv_buf, size_t rcv_msg_len, void ** out_msg, short * out_msg_type, int64_t * nonce, short is_server, vector_clock ** vc);
int read_full_packet(int * sockfd, char * inbuf, size_t inbuf_size, int * msg_len, int * statusp, int (*handle_socket_close)(int * sockfd, int * status));
int sockaddr_cmp(WORD a1, WORD a2);

// Remote server mgmt fctns:

typedef struct remote_server
{
	char hostname[256];
	unsigned short portno;
	int sockfd;
    pthread_mutex_t* sockfd_lock;
	struct sockaddr_in serveraddr;
	struct hostent *server;
	char id[256];
	int status;
	char in_buf[BUFSIZE];
//	char out_buf[BUFSIZE];
} remote_server;

remote_server * get_remote_server(char *hostname, unsigned short portno, struct sockaddr_in serveraddr, int serverfd, int do_connect);
int update_listen_socket(remote_server * rs, char *hostname, unsigned short portno, int do_connect);
int connect_remote_server(remote_server * rs);
void free_remote_server(remote_server * rs);
void free_remote_server_ptr(WORD ptr);


#endif /* BACKEND_COMM_H_ */
