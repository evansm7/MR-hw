/* Make a .hex "readmemh"-compatible file from a binary,
 * a lot faster than the python version.
 *
 * Copyright 2022 Matt Evans
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <endian.h>


#define BSZ 4096
#define TBSZ BSZ*3

static uint8_t buffer[BSZ];
static uint8_t text_buffer[TBSZ];


static unsigned int dump_hex(uint8_t *textbuff, uint8_t *b, unsigned int length)
{
        /* Output 16 chars for two 4-byte LE ints on a line (in a funny order).
         * Length might not be a multiple of 8, so pad.
         */
        unsigned int l = length/8;
        unsigned int tidx = 0;

        for (unsigned int i = 0; i < l; i++) {
                uint32_t wa = le32toh(*(uint32_t *)&b[i*8 + 0]);
                uint32_t wb = le32toh(*(uint32_t *)&b[i*8 + 4]);
                tidx += snprintf(&textbuff[tidx], TBSZ-tidx, "%08x%08x\n", wb, wa);
        }
        // Deal with any remainder:
        unsigned int r = length & 7;

        if (r > 0) {
                uint32_t wa = le32toh(*(uint32_t *)&b[l*8 + 0]);
                uint32_t wb = 0;

                if (r > 4) {
                        wb = le32toh(*(uint32_t *)&b[l*8 + 4]);
                        wb <<= ((4-r) * 8);
                        wb >>= ((4-r) * 8);
                        tidx += snprintf(&textbuff[tidx], TBSZ-tidx, "%08x%08x\n", wb, wa);
                } else {
                        wa <<= ((4-r) * 8);
                        wa >>= ((4-r) * 8);
                        tidx += snprintf(&textbuff[tidx], TBSZ-tidx, "00000000%08x\n", wa);
                }
        }
        return tidx;
}

int main(int argc, char *argv[])
{
        if (argc != 3) {
                printf("Syntax:  %s <in> <out>\n", argv[0]);
                return 1;
        }

        char *infile = argv[1];
        char *outfile = argv[2];

        int ifd = open(infile, O_RDONLY);
        if (ifd < 0) {
                perror("Infile: ");
                return 1;
        }

        struct stat sb;
        fstat(ifd, &sb);

        int ofd = open(outfile, O_RDWR | O_CREAT, 0644);
        if (ofd < 0) {
                perror("Outfile: ");
                return 1;
        }

        unsigned long length = sb.st_size;

        for (unsigned int so_far = 0; so_far < length; so_far += BSZ) {
                int r = read(ifd, buffer, BSZ);

                if (r < 0) {
                        perror("Read: ");
                        return 1;
                }

                unsigned int l = dump_hex(text_buffer, buffer, r);
                r = write(ofd, text_buffer, l);
                if (r < 0) {
                        perror("Write: ");
                        return 1;
                } else if (r != l) {
                        printf("Short write %d!\n", r);
                        return 1;
                }
        }
        close(ifd);
        close(ofd);

        return 0;
}
