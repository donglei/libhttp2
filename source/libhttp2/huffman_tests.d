/*
 * nghttp2 - HTTP/2 C Library
 *
 * Copyright (c) 2013 Tatsuhiro Tsujikawa
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
 * LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
 * OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
 * WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
module libhttp2.huffman_tests;
import libhttp2.buffers;
import libhttp2.huffman;
import libhttp2.deflater;
import libhttp2.inflater;
import libhttp2.types;
import libhttp2.frame;
import libhttp2.helpers;
import libhttp2.tests;

ref HDEntry getEntry(HDTable table, size_t index) {
	return table.get(index);
}

void test_http2_hd_deflate(void) {
	Deflater deflater = Deflater(DEFAULT_MAX_DEFLATE_BUFFER_SIZE);
	Inflater inflater = Inflater(true);
	HeaderField[] hfa1 = [HeaderField(":path", "/my-example/index.html"), HeaderField(":scheme", "https"), HeaderField("hello", "world")];
	HeaderField[] hfa2 = [HeaderField(":path", "/script.js"), HeaderField(":scheme", "https")];
	HeaderField[] hfa3 = [HeaderField("cookie", "k1=v1"), HeaderField("cookie", "k2=v2"), HeaderField("via", "proxy")];
	HeaderField[] hfa4 = [HeaderField(":path", "/style.css"), HeaderField("cookie", "k1=v1"), HeaderField("cookie", "k1=v1")];
	HeaderField[] hfa5 = [HeaderField(":path", "/style.css"), HeaderField("x-nghttp2", "")];
	http2_bufs bufs;
	size_t blocklen;
	HeaderFields output;
	int rv;
	http2_mem *mem;
	
	mem = http2_mem_default();
	frame_pack_bufs_init(&bufs);
	
	
	assert(0 == http2_hd_deflate_init(&deflater, mem));
	assert(0 == http2_hd_inflate_init(&inflater, mem));
	
	rv = deflater.deflate(bufs, nva1, ARRLEN(nva1));
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen > 0);
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(3 == output.length);
	assert_nv_equal(nva1, output[0 .. 3]);
	
	output.reset();
	bufs.reset();
	
	/* Second headers */
	rv = deflater.deflate(bufs, nva2, ARRLEN(nva2));
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen > 0);
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(2 == output.length);
	assert_nv_equal(nva2, output[0 .. 2]);
	
	output.reset();
	bufs.reset();
	
	/* Third headers, including same header field name, but value is not
     the same. */
	rv = deflater.deflate(bufs, nva3, ARRLEN(nva3));
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen > 0);
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(3 == output.length);
	assert_nv_equal(nva3, output[0 .. 3]);
	
	output.reset();
	bufs.reset();
	
	/* Fourth headers, including duplicate header fields. */
	rv = deflater.deflate(bufs, nva4, ARRLEN(nva4));
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen > 0);
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(3 == output.length);
	assert_nv_equal(nva4, output[0 .. 3]);
	
	output.reset();
	bufs.reset();
	
	/* Fifth headers includes empty value */
	rv = deflater.deflate(bufs, nva5, ARRLEN(nva5));
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen > 0);
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(2 == output.length);
	assert_nv_equal(nva5, output[0 .. 2]);
	
	output.reset();
	bufs.reset();
	
	/* Cleanup */
	bufs.free();
	inflater.free();
	http2_hd_deflate_free(&deflater);
}

void test_http2_hd_deflate_same_indexed_repr(void) {
	Deflater deflater = Deflater(DEFAULT_MAX_DEFLATE_BUFFER_SIZE);
	Inflater inflater = Inflater(true);
	HeaderField hfa1[] = [HeaderField("cookie", "alpha"), HeaderField("cookie", "alpha")];
	HeaderField hfa2[] = [HeaderField("cookie", "alpha"), HeaderField("cookie", "alpha"),
		HeaderField("cookie", "alpha")];
	http2_bufs bufs;
	size_t blocklen;
	HeaderFields output;
	int rv;
	http2_mem *mem;
	
	mem = http2_mem_default();
	frame_pack_bufs_init(&bufs);
	
	
	assert(0 == http2_hd_deflate_init(&deflater, mem));
	assert(0 == http2_hd_inflate_init(&inflater, mem));
	
	/* Encode 2 same headers.  Emit 1 literal reprs and 1 index repr. */
	rv = deflater.deflate(bufs, nva1, ARRLEN(nva1));
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen > 0);
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(2 == output.length);
	assert_nv_equal(nva1.equals(output.hfa));
	
	output.reset();
	bufs.reset();
	
	/* Encode 3 same headers.  This time, emits 3 index reprs. */
	rv = deflater.deflate(bufs, nva2, ARRLEN(nva2));
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen == 3);
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(3 == output.length);
	assert_nv_equal(nva2, output[0 .. 3]);
	
	output.reset();
	bufs.reset();
	
	/* Cleanup */
	bufs.free();
	inflater.free();
	http2_hd_deflate_free(&deflater);
}

void test_http2_hd_inflate_indexed(void) {
	Inflater inflater = Inflater(true);
	http2_bufs bufs;
	size_t blocklen;
	HeaderField hf = HeaderField(":path", "/");
	HeaderFields output;
	http2_mem *mem;
	
	mem = http2_mem_default();
	frame_pack_bufs_init(&bufs);
	
	
	
	
	http2_bufs_addb(&bufs, (1 << 7) | 4);
	
	blocklen = bufs.length;
	
	assert(1 == blocklen);
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(1 == output.length);
	
	assert_nv_equal(&nv, output[0 .. 1]);
	
	output.reset();
	bufs.reset();
	
	/* index = 0 is error */
	http2_bufs_addb(&bufs, 1 << 7);
	
	blocklen = bufs.length;
	
	assert(1 == blocklen);
	assert(HTTP2_ERR_HEADER_COMP == inflate_hd(&inflater, &output, &bufs, 0));
	
	bufs.free();
	inflater.free();
}

void test_http2_hd_inflate_indname_noinc(void) {
	Inflater inflater = Inflater(true);
	http2_bufs bufs;
	size_t blocklen;
	HeaderField hf[] = [/* Huffman */
		HeaderField("user-agent", "nghttp2"),
		/* Expecting no huffman */
		HeaderField("user-agent", "x")];
	size_t i;
	HeaderFields output;
	http2_mem *mem;
	
	mem = http2_mem_default();
	frame_pack_bufs_init(&bufs);
	
	
	
	
	for (i = 0; i < ARRLEN(nv); ++i) {
		assert(0 == http2_hd_emit_indname_block(&bufs, 57, &nv[i], 0));
		
		blocklen = bufs.length;
		
		assert(blocklen > 0);
		assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
		
		assert(1 == output.length);
		assert_nv_equal(&nv[i], output[0 .. 1]);
		assert(0 == inflater.ctx.hd_table.len);
		
		output.reset();
		bufs.reset();
	}
	
	bufs.free();
	inflater.free();
}

void test_http2_hd_inflate_indname_inc(void) {
	Inflater inflater = Inflater(true);
	http2_bufs bufs;
	size_t blocklen;
	HeaderField hf = HeaderField("user-agent", "nghttp2");
	HeaderFields output;
	http2_mem *mem;
	
	mem = http2_mem_default();
	frame_pack_bufs_init(&bufs);
	
	
	
	
	assert(0 == http2_hd_emit_indname_block(&bufs, 57, &nv, 1));
	
	blocklen = bufs.length;
	
	assert(blocklen > 0);
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(1 == output.length);
	assert_nv_equal(&nv, output[0 .. 1]);
	assert(1 == inflater.ctx.hd_table.len);
	assert_nv_equal(
		&nv, &getEntry(&inflater.ctx, HTTP2_STATIC_TABLE_LENGTH +
			inflater.ctx.hd_table.len - 1)->nv,
		1);
	
	output.reset();
	bufs.free();
	inflater.free();
}

void test_http2_hd_inflate_indname_inc_eviction(void) {
	Inflater inflater = Inflater(true);
	http2_bufs bufs;
	size_t blocklen;
	ubyte value[1024];
	HeaderFields output;
	HeaderField hf;
	http2_mem *mem;
	
	mem = http2_mem_default();
	frame_pack_bufs_init(&bufs);
	
	
	
	
	memset(value, '0', sizeof(value));
	nv.value = value;
	nv.value.length = sizeof(value);
	
	nv.flag = HeaderFlag.NONE;
	
	assert(0 == http2_hd_emit_indname_block(&bufs, 14, &nv, 1));
	assert(0 == http2_hd_emit_indname_block(&bufs, 15, &nv, 1));
	assert(0 == http2_hd_emit_indname_block(&bufs, 16, &nv, 1));
	assert(0 == http2_hd_emit_indname_block(&bufs, 17, &nv, 1));
	
	blocklen = bufs.length;
	
	assert(blocklen > 0);
	
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(4 == output.length);
	assert(14 == output.hfa[0].name.length);
	assert(0 == memcmp("accept-charset", output.hfa[0].name, output.hfa[0].name.length));
	assert(sizeof(value) == output.hfa[0].value.length);
	
	output.reset();
	bufs.reset();
	
	assert(3 == inflater.ctx.hd_table.len);
	
	bufs.free();
	inflater.free();
}

void test_http2_hd_inflate_newname_noinc(void) {
	Inflater inflater = Inflater(true);
	http2_bufs bufs;
	size_t blocklen;
	HeaderField hf[] = [/* Expecting huffman for both */
		HeaderField("my-long-content-length", "nghttp2"),
		/* Expecting no huffman for both */
		HeaderField("x", "y"),
		/* Huffman for key only */
		HeaderField("my-long-content-length", "y"),
		/* Huffman for value only */
		HeaderField("x", "nghttp2")];
	size_t i;
	HeaderFields output;
	http2_mem *mem;
	
	mem = http2_mem_default();
	frame_pack_bufs_init(&bufs);
	
	
	
	for (i = 0; i < ARRLEN(nv); ++i) {
		assert(0 == http2_hd_emit_newname_block(&bufs, &nv[i], 0));
		
		blocklen = bufs.length;
		
		assert(blocklen > 0);
		assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
		
		assert(1 == output.length);
		assert_nv_equal(&nv[i], output[0 .. 1]);
		assert(0 == inflater.ctx.hd_table.len);
		
		output.reset();
		bufs.reset();
	}
	
	bufs.free();
	inflater.free();
}

void test_http2_hd_inflate_newname_inc(void) {
	Inflater inflater = Inflater(true);
	http2_bufs bufs;
	size_t blocklen;
	HeaderField hf = HeaderField("x-rel", "nghttp2");
	HeaderFields output;
	http2_mem *mem;
	
	mem = http2_mem_default();
	frame_pack_bufs_init(&bufs);
	
	
	
	
	assert(0 == http2_hd_emit_newname_block(&bufs, &nv, 1));
	
	blocklen = bufs.length;
	
	assert(blocklen > 0);
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(1 == output.length);
	assert_nv_equal(&nv, output[0 .. 1]);
	assert(1 == inflater.ctx.hd_table.len);
	assert_nv_equal(
		&nv, &getEntry(&inflater.ctx, HTTP2_STATIC_TABLE_LENGTH +
			inflater.ctx.hd_table.len - 1)->nv,
		1);
	
	output.reset();
	bufs.free();
	inflater.free();
}

void test_http2_hd_inflate_clearall_inc(void) {
	Inflater inflater = Inflater(true);
	http2_bufs bufs;
	size_t blocklen;
	HeaderField hf;
	ubyte[4060] value;
	HeaderFields output;
	http2_mem *mem;
	
	mem = http2_mem_default();
	bufs_large_init(&bufs, 8192);
	
	
	/* Total 4097 bytes space required to hold this entry */
	nv.name = "alpha";
	nv.value = value;
	nv.flag = HeaderFlag.NONE;
	
	
	
	assert(0 == http2_hd_emit_newname_block(&bufs, &nv, 1));
	
	blocklen = bufs.length;
	
	assert(blocklen > 0);
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(1 == output.length);
	assert_nv_equal(&nv, output[0 .. 1]);
	assert(0 == inflater.ctx.hd_table.len);
	
	output.reset();
	
	/* Do it again */
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(1 == output.length);
	assert_nv_equal(&nv, output[0 .. 1]);
	assert(0 == inflater.ctx.hd_table.len);
	
	output.reset();
	bufs.reset();
	
	/* This time, 4096 bytes space required, which is just fits in the
     header table */
	nv.value.length = sizeof(value) - 1;
	
	assert(0 == http2_hd_emit_newname_block(&bufs, &nv, 1));
	
	blocklen = bufs.length;
	
	assert(blocklen > 0);
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(1 == output.length);
	assert_nv_equal(&nv, output[0 .. 1]);
	assert(1 == inflater.ctx.hd_table.len);
	
	output.reset();
	bufs.reset();
	
	bufs.free();
	inflater.free();
}

void test_http2_hd_inflate_zero_length_huffman(void) {
	Inflater inflater = Inflater(true);
	http2_bufs bufs;
	/* Literal header without indexing - new name */
	ubyte data[] = [0x40, 0x01, 0x78 /* 'x' */, 0x80];
	HeaderFields output;
	http2_mem *mem;
	
	mem = http2_mem_default();
	frame_pack_bufs_init(&bufs);
	
	
	
	http2_bufs_add(&bufs, data, sizeof(data));
	
	/* /\* Literal header without indexing - new name *\/ */
	/* ptr[0] = 0x40; */
	/* ptr[1] = 1; */
	/* ptr[2] = 'x'; */
	/* ptr[3] = 0x80; */
	
	
	assert(4 == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(1 == output.length);
	assert(1 == output.hfa[0].name.length);
	assert('x' == output.hfa[0].name[0]);
	assert(NULL == output.hfa[0].value);
	assert(0 == output.hfa[0].value.length);
	
	output.reset();
	bufs.free();
	inflater.free();
}

void test_http2_hd_ringbuf_reserve(void) {
	Deflater deflater = Deflater(DEFAULT_MAX_DEFLATE_BUFFER_SIZE);
	Inflater inflater = Inflater(true);
	HeaderField hf;
	http2_bufs bufs;
	HeaderFields output;
	int i;
	size_t rv;
	size_t blocklen;
	http2_mem *mem;
	
	mem = http2_mem_default();
	frame_pack_bufs_init(&bufs);
	
	
	nv.flag = HeaderFlag.NONE;
	nv.name = (ubyte *)"a";
	nv.name.length = strlen((const char *)nv.name);
	nv.value.length = 4;
	nv.value = malloc(nv.value.length);
	memset(nv.value, 0, nv.value.length);
	
	http2_hd_deflate_init2(&deflater, 8000, mem);
	
	
	http2_hd_inflate_change_table_size(&inflater, 8000);
	http2_hd_deflate_change_table_size(&deflater, 8000);
	
	for (i = 0; i < 150; ++i) {
		memcpy(nv.value, &i, sizeof(i));
		rv = deflater.deflate(bufs, &nv, 1);
		blocklen = bufs.length;
		
		assert(0 == rv);
		assert(blocklen > 0);
		
		assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
		
		assert(1 == output.length);
		assert_nv_equal(&nv, output[0 .. 1]);
		
		output.reset();
		bufs.reset();
	}
	
	bufs.free();
	inflater.free();
	http2_hd_deflate_free(&deflater);
	
	free(nv.value);
}

void test_http2_hd_change_table_size(void) {
	Deflater deflater = Deflater(DEFAULT_MAX_DEFLATE_BUFFER_SIZE);
	Inflater inflater = Inflater(true);
	HeaderField hfa[] = [HeaderField("alpha", "bravo"), HeaderField("charlie", "delta")];
	HeaderField hfa2[] = [HeaderField(":path", "/")];
	http2_bufs bufs;
	size_t rv;
	HeaderFields output;
	size_t blocklen;
	http2_mem *mem;
	
	mem = http2_mem_default();
	frame_pack_bufs_init(&bufs);
	
	
	
	http2_hd_deflate_init(&deflater, mem);
	
	
	/* inflater changes notifies 8000 max header table size */
	assert(0 == http2_hd_inflate_change_table_size(&inflater, 8000));
	assert(0 == http2_hd_deflate_change_table_size(&deflater, 8000));
	
	assert(4096 == deflater.ctx.hd_table_bufsize_max);
	
	assert(8000 == inflater.ctx.hd_table_bufsize_max);
	assert(8000 == inflater.settings_hd_table_bufsize_max);
	
	/* This will emit encoding context update with header table size 4096 */
	rv = deflater.deflate(bufs, nva, 2);
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen > 0);
	assert(2 == deflater.ctx.hd_table.len);
	assert(4096 == deflater.ctx.hd_table_bufsize_max);
	
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	assert(2 == inflater.ctx.hd_table.len);
	assert(4096 == inflater.ctx.hd_table_bufsize_max);
	assert(8000 == inflater.settings_hd_table_bufsize_max);
	
	output.reset();
	bufs.reset();
	
	/* inflater changes header table size to 1024 */
	assert(0 == http2_hd_inflate_change_table_size(&inflater, 1024));
	assert(0 == http2_hd_deflate_change_table_size(&deflater, 1024));
	
	assert(1024 == deflater.ctx.hd_table_bufsize_max);
	
	assert(1024 == inflater.ctx.hd_table_bufsize_max);
	assert(1024 == inflater.settings_hd_table_bufsize_max);
	
	rv = deflater.deflate(bufs, nva, 2);
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen > 0);
	assert(2 == deflater.ctx.hd_table.len);
	assert(1024 == deflater.ctx.hd_table_bufsize_max);
	
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	assert(2 == inflater.ctx.hd_table.len);
	assert(1024 == inflater.ctx.hd_table_bufsize_max);
	assert(1024 == inflater.settings_hd_table_bufsize_max);
	
	output.reset();
	bufs.reset();
	
	/* inflater changes header table size to 0 */
	assert(0 == http2_hd_inflate_change_table_size(&inflater, 0));
	assert(0 == http2_hd_deflate_change_table_size(&deflater, 0));
	
	assert(0 == deflater.ctx.hd_table.len);
	assert(0 == deflater.ctx.hd_table_bufsize_max);
	
	assert(0 == inflater.ctx.hd_table.len);
	assert(0 == inflater.ctx.hd_table_bufsize_max);
	assert(0 == inflater.settings_hd_table_bufsize_max);
	
	rv = deflater.deflate(bufs, nva, 2);
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen > 0);
	assert(0 == deflater.ctx.hd_table.len);
	assert(0 == deflater.ctx.hd_table_bufsize_max);
	
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	assert(0 == inflater.ctx.hd_table.len);
	assert(0 == inflater.ctx.hd_table_bufsize_max);
	assert(0 == inflater.settings_hd_table_bufsize_max);
	
	output.reset();
	bufs.reset();
	
	bufs.free();
	inflater.free();
	http2_hd_deflate_free(&deflater);
	
	/* Check table buffer is expanded */
	frame_pack_bufs_init(&bufs);
	
	http2_hd_deflate_init2(&deflater, 8192, mem);
	
	
	/* First inflater changes header table size to 8000 */
	assert(0 == http2_hd_inflate_change_table_size(&inflater, 8000));
	assert(0 == http2_hd_deflate_change_table_size(&deflater, 8000));
	
	assert(8000 == deflater.ctx.hd_table_bufsize_max);
	
	assert(8000 == inflater.ctx.hd_table_bufsize_max);
	assert(8000 == inflater.settings_hd_table_bufsize_max);
	
	rv = deflater.deflate(bufs, nva, 2);
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen > 0);
	assert(2 == deflater.ctx.hd_table.len);
	assert(8000 == deflater.ctx.hd_table_bufsize_max);
	
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	assert(2 == inflater.ctx.hd_table.len);
	assert(8000 == inflater.ctx.hd_table_bufsize_max);
	assert(8000 == inflater.settings_hd_table_bufsize_max);
	
	output.reset();
	bufs.reset();
	
	assert(0 == http2_hd_inflate_change_table_size(&inflater, 16383));
	assert(0 == http2_hd_deflate_change_table_size(&deflater, 16383));
	
	assert(8192 == deflater.ctx.hd_table_bufsize_max);
	
	assert(16383 == inflater.ctx.hd_table_bufsize_max);
	assert(16383 == inflater.settings_hd_table_bufsize_max);
	
	rv = deflater.deflate(bufs, nva, 2);
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen > 0);
	assert(2 == deflater.ctx.hd_table.len);
	assert(8192 == deflater.ctx.hd_table_bufsize_max);
	
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	assert(2 == inflater.ctx.hd_table.len);
	assert(8192 == inflater.ctx.hd_table_bufsize_max);
	assert(16383 == inflater.settings_hd_table_bufsize_max);
	
	output.reset();
	bufs.reset();
	
	/* Lastly, check the error condition */
	
	rv = http2_hd_emit_table_size(&bufs, 25600);
	assert(rv == 0);
	assert(HTTP2_ERR_HEADER_COMP == inflate_hd(&inflater, &output, &bufs, 0));
	
	output.reset();
	bufs.reset();
	
	inflater.free();
	http2_hd_deflate_free(&deflater);
	
	/* Check that encoder can handle the case where its allowable buffer
     size is less than default size, 4096 */
	http2_hd_deflate_init2(&deflater, 1024, mem);
	
	
	assert(1024 == deflater.ctx.hd_table_bufsize_max);
	
	/* This emits context update with buffer size 1024 */
	rv = deflater.deflate(bufs, nva, 2);
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen > 0);
	assert(2 == deflater.ctx.hd_table.len);
	assert(1024 == deflater.ctx.hd_table_bufsize_max);
	
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	assert(2 == inflater.ctx.hd_table.len);
	assert(1024 == inflater.ctx.hd_table_bufsize_max);
	assert(4096 == inflater.settings_hd_table_bufsize_max);
	
	output.reset();
	bufs.reset();
	
	inflater.free();
	http2_hd_deflate_free(&deflater);
	
	/* Check that table size UINT32_MAX can be received */
	http2_hd_deflate_init2(&deflater, UINT32_MAX, mem);
	
	
	assert(0 == http2_hd_inflate_change_table_size(&inflater, UINT32_MAX));
	assert(0 == http2_hd_deflate_change_table_size(&deflater, UINT32_MAX));
	
	rv = deflater.deflate(bufs, nva, 2);
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(UINT32_MAX == deflater.ctx.hd_table_bufsize_max);
	
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	assert(UINT32_MAX == inflater.ctx.hd_table_bufsize_max);
	assert(UINT32_MAX == inflater.settings_hd_table_bufsize_max);
	
	output.reset();
	bufs.reset();
	
	inflater.free();
	http2_hd_deflate_free(&deflater);
	
	/* Check that context update emitted twice */
	http2_hd_deflate_init2(&deflater, 4096, mem);
	
	
	assert(0 == http2_hd_inflate_change_table_size(&inflater, 0));
	assert(0 == http2_hd_inflate_change_table_size(&inflater, 3000));
	assert(0 == http2_hd_deflate_change_table_size(&deflater, 0));
	assert(0 == http2_hd_deflate_change_table_size(&deflater, 3000));
	
	assert(0 == deflater.min_hd_table_bufsize_max);
	assert(3000 == deflater.ctx.hd_table_bufsize_max);
	
	rv = deflater.deflate(bufs, nva2, 1);
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(3 < blocklen);
	assert(3000 == deflater.ctx.hd_table_bufsize_max);
	assert(UINT32_MAX == deflater.min_hd_table_bufsize_max);
	
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	assert(3000 == inflater.ctx.hd_table_bufsize_max);
	assert(3000 == inflater.settings_hd_table_bufsize_max);
	
	output.reset();
	bufs.reset();
	
	inflater.free();
	http2_hd_deflate_free(&deflater);
	
	bufs.free();
}

static void check_deflate_inflate(http2_hd_deflater *deflater,
	http2_hd_inflater *inflater,
	http2_nv *nva, size_t nvlen) {
	http2_bufs bufs;
	size_t blocklen;
	HeaderFields output;
	int rv;
	
	frame_pack_bufs_init(&bufs);
	
	
	rv = http2_hd_deflate_hd_bufs(deflater, &bufs, nva, nvlen);
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen >= 0);
	
	assert(blocklen == inflate_hd(inflater, &output, &bufs, 0));
	
	assert(nvlen == output.length);
	assert_nv_equal(nva, output.hfa, nvlen);
	
	output.reset();
	bufs.free();
}

void test_http2_hd_deflate_inflate(void) {
	Deflater deflater = Deflater(DEFAULT_MAX_DEFLATE_BUFFER_SIZE);
	Inflater inflater = Inflater(true);
	HeaderField hf1[] = [
		HeaderField(":status", "200 OK"),
		HeaderField("access-control-allow-origin", "*"),
		HeaderField("cache-control", "private, max-age=0, must-revalidate"),
		HeaderField("content-length", "76073"),
		HeaderField("content-type", "text/html"),
		HeaderField("date", "Sat, 27 Jul 2013 06:22:12 GMT"),
		HeaderField("expires", "Sat, 27 Jul 2013 06:22:12 GMT"),
		HeaderField("server", "Apache"),
		HeaderField("vary", "foobar"),
		HeaderField("via", "1.1 alphabravo (squid/3.x.x), 1.1 nghttpx"),
		HeaderField("x-cache", "MISS from alphabravo"),
		HeaderField("x-cache-action", "MISS"),
		HeaderField("x-cache-age", "0"),
		HeaderField("x-cache-lookup", "MISS from alphabravo:3128"),
		HeaderField("x-lb-nocache", "true"),
	];
	HeaderField hf2[] = [
		HeaderField(":status", "304 Not Modified"),
		HeaderField("age", "0"),
		HeaderField("cache-control", "max-age=56682045"),
		HeaderField("content-type", "text/css"),
		HeaderField("date", "Sat, 27 Jul 2013 06:22:12 GMT"),
		HeaderField("expires", "Thu, 14 May 2015 07:22:57 GMT"),
		HeaderField("last-modified", "Tue, 14 May 2013 07:22:15 GMT"),
		HeaderField("vary", "Accept-Encoding"),
		HeaderField("via", "1.1 alphabravo (squid/3.x.x), 1.1 nghttpx"),
		HeaderField("x-cache", "HIT from alphabravo"),
		HeaderField("x-cache-lookup", "HIT from alphabravo:3128")];
	HeaderField hf3[] = [
		HeaderField(":status", "304 Not Modified"),
		HeaderField("age", "0"),
		HeaderField("cache-control", "max-age=56682072"),
		HeaderField("content-type", "text/css"),
		HeaderField("date", "Sat, 27 Jul 2013 06:22:12 GMT"),
		HeaderField("expires", "Thu, 14 May 2015 07:23:24 GMT"),
		HeaderField("last-modified", "Tue, 14 May 2013 07:22:13 GMT"),
		HeaderField("vary", "Accept-Encoding"),
		HeaderField("via", "1.1 alphabravo (squid/3.x.x), 1.1 nghttpx"),
		HeaderField("x-cache", "HIT from alphabravo"),
		HeaderField("x-cache-lookup", "HIT from alphabravo:3128"),
	];
	HeaderField hf4[] = [
		HeaderField(":status", "304 Not Modified"),
		HeaderField("age", "0"),
		HeaderField("cache-control", "max-age=56682022"),
		HeaderField("content-type", "text/css"),
		HeaderField("date", "Sat, 27 Jul 2013 06:22:12 GMT"),
		HeaderField("expires", "Thu, 14 May 2015 07:22:34 GMT"),
		HeaderField("last-modified", "Tue, 14 May 2013 07:22:14 GMT"),
		HeaderField("vary", "Accept-Encoding"),
		HeaderField("via", "1.1 alphabravo (squid/3.x.x), 1.1 nghttpx"),
		HeaderField("x-cache", "HIT from alphabravo"),
		HeaderField("x-cache-lookup", "HIT from alphabravo:3128"),
	];
	HeaderField hf5[] = [
		HeaderField(":status", "304 Not Modified"),
		HeaderField("age", "0"),
		HeaderField("cache-control", "max-age=4461139"),
		HeaderField("content-type", "application/x-javascript"),
		HeaderField("date", "Sat, 27 Jul 2013 06:22:12 GMT"),
		HeaderField("expires", "Mon, 16 Sep 2013 21:34:31 GMT"),
		HeaderField("last-modified", "Thu, 05 May 2011 09:15:59 GMT"),
		HeaderField("vary", "Accept-Encoding"),
		HeaderField("via", "1.1 alphabravo (squid/3.x.x), 1.1 nghttpx"),
		HeaderField("x-cache", "HIT from alphabravo"),
		HeaderField("x-cache-lookup", "HIT from alphabravo:3128"),
	];
	HeaderField hf6[] = [
		HeaderField(":status", "304 Not Modified"),
		HeaderField("age", "0"),
		HeaderField("cache-control", "max-age=18645951"),
		HeaderField("content-type", "application/x-javascript"),
		HeaderField("date", "Sat, 27 Jul 2013 06:22:12 GMT"),
		HeaderField("expires", "Fri, 28 Feb 2014 01:48:03 GMT"),
		HeaderField("last-modified", "Tue, 12 Jul 2011 16:02:59 GMT"),
		HeaderField("vary", "Accept-Encoding"),
		HeaderField("via", "1.1 alphabravo (squid/3.x.x), 1.1 nghttpx"),
		HeaderField("x-cache", "HIT from alphabravo"),
		HeaderField("x-cache-lookup", "HIT from alphabravo:3128"),
	];
	HeaderField hf7[] = [
		HeaderField(":status", "304 Not Modified"),
		HeaderField("age", "0"),
		HeaderField("cache-control", "max-age=31536000"),
		HeaderField("content-type", "application/javascript"),
		HeaderField("date", "Sat, 27 Jul 2013 06:22:12 GMT"),
		HeaderField("etag", "\"6807-4dc5b54e0dcc0\""),
		HeaderField("expires", "Wed, 21 May 2014 08:32:17 GMT"),
		HeaderField("last-modified", "Fri, 10 May 2013 11:18:51 GMT"),
		HeaderField("via", "1.1 alphabravo (squid/3.x.x), 1.1 nghttpx"),
		HeaderField("x-cache", "HIT from alphabravo"),
		HeaderField("x-cache-lookup", "HIT from alphabravo:3128"),
	];
	HeaderField hf8[] = [
		HeaderField(":status", "304 Not Modified"),
		HeaderField("age", "0"),
		HeaderField("cache-control", "max-age=31536000"),
		HeaderField("content-type", "application/javascript"),
		HeaderField("date", "Sat, 27 Jul 2013 06:22:12 GMT"),
		HeaderField("etag", "\"41c6-4de7d28585b00\""),
		HeaderField("expires", "Thu, 12 Jun 2014 10:00:58 GMT"),
		HeaderField("last-modified", "Thu, 06 Jun 2013 14:30:36 GMT"),
		HeaderField("via", "1.1 alphabravo (squid/3.x.x), 1.1 nghttpx"),
		HeaderField("x-cache", "HIT from alphabravo"),
		HeaderField("x-cache-lookup", "HIT from alphabravo:3128"),
	];
	HeaderField hf9[] = [
		HeaderField(":status", "304 Not Modified"),
		HeaderField("age", "0"),
		HeaderField("cache-control", "max-age=31536000"),
		HeaderField("content-type", "application/javascript"),
		HeaderField("date", "Sat, 27 Jul 2013 06:22:12 GMT"),
		HeaderField("etag", "\"19d6e-4dc5b35a541c0\""),
		HeaderField("expires", "Wed, 21 May 2014 08:32:18 GMT"),
		HeaderField("last-modified", "Fri, 10 May 2013 11:10:07 GMT"),
		HeaderField("via", "1.1 alphabravo (squid/3.x.x), 1.1 nghttpx"),
		HeaderField("x-cache", "HIT from alphabravo"),
		HeaderField("x-cache-lookup", "HIT from alphabravo:3128"),
	];
	HeaderField hf10[] = [
		HeaderField(":status", "304 Not Modified"),
		HeaderField("age", "0"),
		HeaderField("cache-control", "max-age=56682045"),
		HeaderField("content-type", "text/css"),
		HeaderField("date", "Sat, 27 Jul 2013 06:22:12 GMT"),
		HeaderField("expires", "Thu, 14 May 2015 07:22:57 GMT"),
		HeaderField("last-modified", "Tue, 14 May 2013 07:21:53 GMT"),
		HeaderField("vary", "Accept-Encoding"),
		HeaderField("via", "1.1 alphabravo (squid/3.x.x), 1.1 nghttpx"),
		HeaderField("x-cache", "HIT from alphabravo"),
		HeaderField("x-cache-lookup", "HIT from alphabravo:3128"),
	];
	http2_mem *mem;
	
	mem = http2_mem_default();
	
	http2_hd_deflate_init(&deflater, mem);
	
	
	check_deflate_inflate(&deflater, &inflater, nv1, ARRLEN(nv1));
	check_deflate_inflate(&deflater, &inflater, nv2, ARRLEN(nv2));
	check_deflate_inflate(&deflater, &inflater, nv3, ARRLEN(nv3));
	check_deflate_inflate(&deflater, &inflater, nv4, ARRLEN(nv4));
	check_deflate_inflate(&deflater, &inflater, nv5, ARRLEN(nv5));
	check_deflate_inflate(&deflater, &inflater, nv6, ARRLEN(nv6));
	check_deflate_inflate(&deflater, &inflater, nv7, ARRLEN(nv7));
	check_deflate_inflate(&deflater, &inflater, nv8, ARRLEN(nv8));
	check_deflate_inflate(&deflater, &inflater, nv9, ARRLEN(nv9));
	check_deflate_inflate(&deflater, &inflater, nv10, ARRLEN(nv10));
	
	inflater.free();
	http2_hd_deflate_free(&deflater);
}

void test_http2_hd_no_index(void) {
	Deflater deflater = Deflater(DEFAULT_MAX_DEFLATE_BUFFER_SIZE);
	Inflater inflater = Inflater(true);
	http2_bufs bufs;
	size_t blocklen;
	HeaderField hfa[] = [
		HeaderField(":method", "GET"), HeaderField(":method", "POST"),
		HeaderField(":path", "/foo"),  HeaderField("version", "HTTP/1.1"),
		HeaderField(":method", "GET"),
	];
	size_t i;
	HeaderFields output;
	int rv;
	http2_mem *mem;
	
	mem = http2_mem_default();
	
	/* 1st :method: GET can be indexable, last one is not */
	for (i = 1; i < ARRLEN(nva); ++i) {
		nva[i].flags = HeaderFlag.NO_INDEX;
	}
	
	frame_pack_bufs_init(&bufs);
	
	
	
	http2_hd_deflate_init(&deflater, mem);
	
	
	rv = deflater.deflate(bufs, nva, ARRLEN(nva));
	blocklen = bufs.length;
	
	assert(0 == rv);
	assert(blocklen > 0);
	assert(blocklen == inflate_hd(&inflater, &output, &bufs, 0));
	
	assert(ARRLEN(nva) == output.length);
	assert_nv_equal(nva, output.hfa, ARRLEN(nva));
	
	assert(output.hfa[0].flags == HeaderFlag.NONE);
	for (i = 1; i < ARRLEN(nva); ++i) {
		assert(output.hfa[i].flags == HeaderFlag.NO_INDEX);
	}
	
	output.reset();
	
	bufs.free();
	inflater.free();
	http2_hd_deflate_free(&deflater);
}

void test_http2_hd_deflate_bound(void) {
	Deflater deflater = Deflater(DEFAULT_MAX_DEFLATE_BUFFER_SIZE);
	HeaderField hfa[] = [HeaderField(":method", "GET"), HeaderField("alpha", "bravo")];
	http2_bufs bufs;
	size_t bound, bound2;
	http2_mem *mem;
	
	mem = http2_mem_default();
	frame_pack_bufs_init(&bufs);
	
	http2_hd_deflate_init(&deflater, mem);
	
	bound = http2_hd_deflate_bound(&deflater, nva, ARRLEN(nva));
	
	assert(12 + 6 * 2 * 2 + nva[0].name.length + nva[0].value.length + nva[1].name.length + nva[1].value.length == bound);
	
	deflater.deflate(bufs, nva, ARRLEN(nva));
	
	assert(bound > cast(size_t)bufs.length);
	
	bound2 = http2_hd_deflate_bound(&deflater, nva, ARRLEN(nva));
	
	assert(bound == bound2);
	
	bufs.free();
	http2_hd_deflate_free(&deflater);
}

void test_http2_hd_public_api(void) {
	http2_hd_deflater *deflater;
	http2_hd_inflater *inflater;
	HeaderField hfa[] = [HeaderField("alpha", "bravo"), HeaderField("charlie", "delta")];
	ubyte buf[4096];
	size_t buflen;
	size_t blocklen;
	http2_bufs bufs;
	http2_mem *mem;
	
	mem = http2_mem_default();
	
	assert(0 == http2_hd_deflate_new(&deflater, 4096));
	assert(0 == http2_hd_inflate_new(&inflater));
	
	buflen = http2_hd_deflate_bound(deflater, nva, ARRLEN(nva));
	
	blocklen = http2_hd_deflate_hd(deflater, buf, buflen, nva, ARRLEN(nva));
	
	assert(blocklen > 0);
	
	http2_bufs_wrap_init(&bufs, buf, blocklen, mem);
	bufs.head->buf.last += blocklen;
	
	assert(blocklen == inflate_hd(inflater, NULL, &bufs, 0));
	
	http2_bufs_wrap_free(&bufs);
	
	http2_hd_inflate_del(inflater);
	http2_hd_deflate_del(deflater);
	
	/* See HTTP2_ERR_INSUFF_BUFSIZE */
	assert(0 == http2_hd_deflate_new(&deflater, 4096));
	
	blocklen =
		http2_hd_deflate_hd(deflater, buf, blocklen - 1, nva, ARRLEN(nva));
	
	assert(HTTP2_ERR_INSUFF_BUFSIZE == blocklen);
	
	http2_hd_deflate_del(deflater);
}

static size_t encode_length(ubyte *buf, ulong n, size_t prefix) {
	size_t k = (1 << prefix) - 1;
	size_t len = 0;
	*buf &= ~k;
	if (n >= k) {
		*buf++ |= k;
		n -= k;
		++len;
	} else {
		*buf++ |= n;
		return 1;
	}
	do {
		++len;
		if (n >= 128) {
			*buf++ = (1 << 7) | (n & 0x7f);
			n >>= 7;
		} else {
			*buf++ = (ubyte)n;
			break;
		}
	} while (n);
	return len;
}

void test_http2_hd_decode_length(void) {
	uint output;
	size_t shift;
	int final;
	ubyte buf[16];
	ubyte *bufp;
	size_t len;
	size_t rv;
	size_t i;
	
	memset(buf, 0, sizeof(buf));
	len = encode_length(buf, UINT32_MAX, 7);
	
	rv = http2_hd_decode_length(&output, &shift, &final, 0, 0, buf, buf + len, 7);
	
	assert(cast(size_t)len == rv);
	assert(0 != final);
	assert(UINT32_MAX == output);
	
	/* Make sure that we can decode integer if we feed 1 byte at a
     time */
	out = 0;
	shift = 0;
	final = 0;
	bufp = buf;
	
	for (i = 0; i < len; ++i, ++bufp) {
		rv = http2_hd_decode_length(&output, &shift, &final, output, shift, bufp,
			bufp + 1, 7);
		
		assert(rv == 1);
		
		if (final) {
			break;
		}
	}
	
	assert(i == len - 1);
	assert(0 != final);
	assert(UINT32_MAX == output);
	
	/* Check overflow case */
	memset(buf, 0, sizeof(buf));
	len = encode_length(buf, 1ll << 32, 7);
	
	rv = http2_hd_decode_length(&output, &shift, &final, 0, 0, buf, buf + len, 7);
	
	assert(-1 == rv);
}

void test_http2_hd_huff_encode(void) {
	int rv;
	size_t len;
	Buffers bufs, outbufs;
	http2_hd_huff_decode_context ctx;
	const ubyte t1[] = [22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11,
		10, 9,  8,  7,  6,  5,  4,  3,  2,  1,  0];
	
	frame_pack_bufs_init(&bufs);
	frame_pack_bufs_init(&outbufs);
	
	rv = http2_hd_huff_encode(&bufs, t1, sizeof(t1));
	
	assert(rv == 0);
	
	http2_hd_huff_decode_context_init(&ctx);
	
	len = http2_hd_huff_decode(&ctx, &outbufs, bufs.cur->buf.pos,
		bufs.length, 1);
	
	assert(bufs.length == len);
	assert(cast(size_t)sizeof(t1) == http2_bufs_len(&outbufs));
	
	assert(0 == memcmp(t1, outbufs.cur->buf.pos, sizeof(t1)));
	
	bufs.free();
	http2_bufs_free(&outbufs);
}
