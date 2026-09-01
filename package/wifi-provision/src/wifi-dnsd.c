/*
 * Copyright (c) OpenIPC  https://openipc.org  MIT License
 *
 * wifi-dnsd -- wildcard DNS responder for the provisioning captive portal.
 *
 * Answers every A query with one fixed address so that whatever hostname a
 * phone probes on joining the setup network resolves to the camera, and its
 * captive-portal check lands on the setup page instead of timing out.
 *
 * Why this exists rather than a dependency:
 *   - BusyBox dnsd is not built into OpenIPC images, and even when it is it
 *     answers only from a static host list -- it has no wildcard, which is
 *     the single thing a captive portal needs.
 *   - dnsmasq does the job and about two hundred others, at roughly 300 KB
 *     on a board whose entire rootfs budget is 8 MB.
 *
 * Deliberately narrow: it is not a resolver and never forwards. It replies
 * to A queries with the configured address, answers AAAA with an empty
 * NOERROR so clients fall back to IPv4 rather than stalling, and refuses
 * everything else. It should only ever be bound to the provisioning
 * interface's own address.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define DNS_PORT       53
#define DNS_MAXMSG     512
#define DNS_HDR_LEN    12
#define DNS_TTL        10

#define TYPE_A         1
#define TYPE_AAAA      28
#define CLASS_IN       1

#define RCODE_OK       0
#define RCODE_FORMERR  1
#define RCODE_NOTIMP   4

static volatile sig_atomic_t running = 1;

static void on_signal(int sig)
{
	(void)sig;
	running = 0;
}

/*
 * Walk the QNAME starting at *off. Returns 0 on success and leaves *off just
 * past the terminating zero length byte. Rejects compression pointers: a
 * query has nothing to point back to, so their presence means either a
 * malformed packet or someone probing for a parser bug.
 */
static int skip_qname(const unsigned char *msg, size_t len, size_t *off)
{
	size_t i = *off;
	unsigned int labels = 0;

	while (i < len) {
		unsigned char l = msg[i];

		if (l == 0) {
			*off = i + 1;
			return 0;
		}
		if ((l & 0xc0) != 0)         /* compression or reserved */
			return -1;
		if (++labels > 63)           /* bounded work per packet */
			return -1;
		i += (size_t)l + 1;
	}
	return -1;
}

static void put16(unsigned char *p, unsigned int v)
{
	p[0] = (unsigned char)((v >> 8) & 0xff);
	p[1] = (unsigned char)(v & 0xff);
}

static void put32(unsigned char *p, unsigned long v)
{
	p[0] = (unsigned char)((v >> 24) & 0xff);
	p[1] = (unsigned char)((v >> 16) & 0xff);
	p[2] = (unsigned char)((v >> 8) & 0xff);
	p[3] = (unsigned char)(v & 0xff);
}

/*
 * Build the reply in place. Returns the reply length, or 0 to send nothing.
 * buf must have room for DNS_MAXMSG bytes; the caller guarantees that.
 */
static size_t build_reply(unsigned char *buf, size_t len, struct in_addr answer)
{
	size_t qname_start, off;
	unsigned int qdcount, qtype, qclass;
	unsigned char rcode = RCODE_OK;
	unsigned int ancount = 0;

	if (len < DNS_HDR_LEN)
		return 0;

	/* Ignore responses; we only ever answer queries. */
	if (buf[2] & 0x80)
		return 0;

	qdcount = ((unsigned int)buf[4] << 8) | buf[5];

	off = DNS_HDR_LEN;
	qname_start = off;

	if (qdcount != 1 || skip_qname(buf, len, &off) != 0 || off + 4 > len) {
		/* Malformed or multi-question: answer the header only. */
		rcode = RCODE_FORMERR;
		off = (len < DNS_HDR_LEN) ? DNS_HDR_LEN : len;
		if (off > DNS_MAXMSG)
			off = DNS_MAXMSG;
		goto emit;
	}

	qtype = ((unsigned int)buf[off] << 8) | buf[off + 1];
	qclass = ((unsigned int)buf[off + 2] << 8) | buf[off + 3];
	off += 4;

	if (qclass != CLASS_IN) {
		rcode = RCODE_NOTIMP;
		goto emit;
	}

	if (qtype == TYPE_A) {
		/*
		 * Answer: a pointer back to the question's name, then the fixed
		 * address. 2 + 2 + 2 + 4 + 2 + 4 = 16 bytes.
		 */
		if (off + 16 > DNS_MAXMSG || qname_start > 0x3fff)
			goto emit;

		put16(buf + off, 0xc000 | (unsigned int)qname_start);
		off += 2;
		put16(buf + off, TYPE_A);
		off += 2;
		put16(buf + off, CLASS_IN);
		off += 2;
		put32(buf + off, DNS_TTL);
		off += 4;
		put16(buf + off, 4);
		off += 2;
		memcpy(buf + off, &answer.s_addr, 4);
		off += 4;
		ancount = 1;
	} else if (qtype != TYPE_AAAA) {
		/*
		 * AAAA gets an empty NOERROR, which tells the client "this name
		 * exists, just not over v6" and makes it ask for A immediately.
		 * Anything else is not our business.
		 */
		rcode = RCODE_NOTIMP;
	}

emit:
	/* QR=1, AA=1, RA=0, preserve opcode and RD from the query. */
	buf[2] = (unsigned char)(0x80 | (buf[2] & 0x7a) | 0x04);
	buf[3] = (unsigned char)(buf[3] & 0x70);
	buf[3] |= rcode;
	put16(buf + 6, ancount);
	put16(buf + 8, 0);            /* NSCOUNT */
	put16(buf + 10, 0);           /* ARCOUNT */
	return off;
}

static void usage(void)
{
	fprintf(stderr, "Usage: wifi-dnsd -a <address> [-p <port>]\n");
}

int main(int argc, char **argv)
{
	struct sockaddr_in bind_addr, peer;
	struct in_addr answer;
	unsigned char buf[DNS_MAXMSG];
	const char *addr_str = NULL;
	int port = DNS_PORT;
	int fd, opt;

	while ((opt = getopt(argc, argv, "a:p:h")) != -1) {
		switch (opt) {
		case 'a':
			addr_str = optarg;
			break;
		case 'p':
			port = atoi(optarg);
			break;
		default:
			usage();
			return (opt == 'h') ? 0 : 1;
		}
	}

	if (addr_str == NULL || port <= 0 || port > 65535) {
		usage();
		return 1;
	}
	if (inet_pton(AF_INET, addr_str, &answer) != 1) {
		fprintf(stderr, "wifi-dnsd: '%s' is not an IPv4 address\n", addr_str);
		return 1;
	}

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	signal(SIGPIPE, SIG_IGN);

	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		perror("wifi-dnsd: socket");
		return 1;
	}

	memset(&bind_addr, 0, sizeof(bind_addr));
	bind_addr.sin_family = AF_INET;
	bind_addr.sin_port = htons((unsigned short)port);
	/*
	 * Bound to the provisioning address only, never INADDR_ANY: this must
	 * not become an open resolver on whatever other network the camera is
	 * attached to.
	 */
	bind_addr.sin_addr = answer;

	if (bind(fd, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
		fprintf(stderr, "wifi-dnsd: bind %s:%d: %s\n",
			addr_str, port, strerror(errno));
		close(fd);
		return 1;
	}

	while (running) {
		socklen_t plen = sizeof(peer);
		ssize_t n = recvfrom(fd, buf, sizeof(buf), 0,
				     (struct sockaddr *)&peer, &plen);
		size_t rlen;

		if (n < 0) {
			if (errno == EINTR)
				continue;
			break;
		}

		rlen = build_reply(buf, (size_t)n, answer);
		if (rlen == 0)
			continue;

		(void)sendto(fd, buf, rlen, 0, (struct sockaddr *)&peer, plen);
	}

	close(fd);
	return 0;
}
