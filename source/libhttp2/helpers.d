﻿/**
 * Helpers
 * 
 * Copyright:
 * (C) 2012-2015 Tatsuhiro Tsujikawa
 * (C) 2014-2015 Etienne Cimon
 *
 * License: 
 * Distributed under the terms of the MIT license with an additional section 1.2 of the curl/libcurl project. 
 * Consult the provided LICENSE.md file for details
 */
module libhttp2.helpers;

import libhttp2.constants;
import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import libhttp2.types;
import std.c.string : memcpy;
import std.string : toLowerInPlace;
import core.exception : onRangeError;
import std.algorithm : max, min;

void write(T)(ubyte* buf, T n) {
	auto x = nativeToBigEndian(n);
	memcpy(buf, x.ptr, T.sizeof);
}

void write(T)(ubyte[] buf, T n) {
	if (buf.length < T.sizeof) onRangeError();
	auto x = nativeToBigEndian(n);
	memcpy(buf.ptr, x.ptr, T.sizeof);
}

T read(T = uint)(in ubyte* buf) {
	return bigEndianToNative!T(buf[0 .. T.sizeof]);
}

T read(T = uint)(in ubyte[] buf) {
	if (buf.length < T.sizeof) onRangeError();
	return bigEndianToNative!T(cast(ubyte[T.sizeof])buf[0 .. T.sizeof]);
}

HeaderField[] copy()(auto const ref HeaderField[] hfa) {
	if (hfa.length == 0)
		return null;

	HeaderField[] ret = Mem.alloc!(HeaderField[])(hfa.length);

	foreach (size_t i, const ref HeaderField hf; hfa) {
		ret[i].flag = hf.flag;
		char[] copy;
		if (hf.name.length > 0)
			copy = copyToLower(hf.name);

		ret[i].name = cast(string) copy;
		if (hf.value.length > 0)
			ret[i].value = Mem.copy(hf.value);
	}
	return ret;
}

/*
 * Makes copy of |iv| and return the copy. This function returns the 
 * copy if it succeeds, or null.
 */
Setting[] copy(in Setting[] iva) {
	if (iva.length == 0)
		return null;
	return cast(Setting[]) Mem.copy(iva);
}


bool equals(in HeaderField[] hfa, in HeaderField[] other) 
{
	import libhttp2.tests : sort;
	auto hfa2 = hfa.copy();
	auto other2 = other.copy();
	scope(exit) {
		foreach(i, ref hf; hfa2) {
			hf.free();
		}
		foreach(i, ref hf; other2) {
			hf.free();
		}
		Mem.free(hfa2);
		Mem.free(other2);
	}
	sort(hfa2);
	sort(other2);
	foreach(i, hf; hfa2)
		if (other2[i] != hf)
			return false;
	return true;
}

void free(ref HeaderField[] hfa)
{
	foreach(ref hf; hfa)
	{
		hf.free();
	}
	Mem.free(hfa);
	hfa = null;
}


/*
 * This function was generated by genlibtokenlookup.py.  Inspired by
 * h2o header lookup.  https://github.com/h2o/h2o
 */
Token parseToken(in string name) {
	with(Token) switch (name.length) {
		case 2:
			switch (name[1]) {
				case 'e':
					if (name[0] == 't') {
						return TE;
					}
					break;
				default: break;
			}
			break;
		case 4:
			switch (name[3]) {
				case 't':
					if (name.ptr[0 .. 3] == "hos") {
						return HOST;
					}
					break;
				default: break;
			}
			break;
		case 5:
			switch (name[4]) {
				case 'h':
					if (name.ptr[0 .. 4] == ":pat") {
						return _PATH;
					}
					break;
				default: break;
			}
			break;
		case 7:
			switch (name[6]) {
				case 'd':
					if (name.ptr[0 .. 6] == ":metho") {
						return _METHOD;
					}
					break;
				case 'e':
					if (name.ptr[0 .. 6] == ":schem") {
						return _SCHEME;
					}
					if (name.ptr[0 .. 6] == "upgrad") {
						return UPGRADE;
					}
					break;
				case 's':
					if (name.ptr[0 .. 6] == ":statu") {
						return _STATUS;
					}
					break;
				default: break;
			}
			break;
		case 10:
			switch (name[9]) {
				case 'e':
					if (name.ptr[0 .. 9] == "keep-aliv") {
						return KEEP_ALIVE;
					}
					break;
				case 'n':
					if (name.ptr[0 .. 9] == "connectio") {
						return CONNECTION;
					}
					break;
				case 'y':
					if (name.ptr[0 .. 9] == ":authorit") {
						return _AUTHORITY;
					}
					break;
				default: break;
			}
			break;
		case 14:
			switch (name[13]) {
				case 'h':
					if (name.ptr[0 .. 13] == "content-lengt") {
						return CONTENT_LENGTH;
					}
					break;
				default: break;
			}
			break;
		case 16:
			switch (name[15]) {
				case 'n':
					if (name.ptr[0 .. 15] == "proxy-connectio") {
						return PROXY_CONNECTION;
					}
					break;
				default: break;
			}
			break;
		case 17:
			switch (name[16]) {
				case 'g':
					if (name.ptr[0 .. 16] == "transfer-encodin") {
						return TRANSFER_ENCODING;
					}
					break;
				default: break;
			}
			break;
		default: break;
	}
	return Token.ERROR;
}


/*
 *   local_window_size
 *   ^  *
 *   |  *    recv_window_size
 *   |  *  * ^
 *   |  *  * |
 *  0+++++++++
 *   |  *  *   \
 *   |  *  *   | This rage is hidden in flow control.  But it must be
 *   v  *  *   / kept in order to restore it when window size is enlarged.
 *   recv_reduction
 *   (+ for negative direction)
 *
 *   recv_window_size could be negative if we decrease
 *   local_window_size more than recv_window_size:
 *
 *   local_window_size
 *   ^  *
 *   |  *
 *   |  *
 *   0++++++++
 *   |  *    ^ recv_window_size (negative)
 *   |  *    |
 *   v  *  *
 *   recv_reduction
 */
ErrorCode adjustLocalWindowSize(ref int local_window_size_ptr, ref int recv_window_size_ptr, ref int recv_reduction_ptr, ref int delta_ptr)
{
	if (delta_ptr > 0) {
		int recv_reduction_delta;
		int delta;
		int new_recv_window_size = max(0, recv_window_size_ptr) - delta_ptr;
		
		if (new_recv_window_size >= 0) 
		{
			recv_window_size_ptr = new_recv_window_size;
			return ErrorCode.OK;
		}
		
		delta = -new_recv_window_size;
		
		/* The delta size is strictly more than received bytes. Increase
       	   local_window_size by that difference |delta|. */
		if (local_window_size_ptr > MAX_WINDOW_SIZE - delta)
		{
			return ErrorCode.FLOW_CONTROL;
		}
		local_window_size_ptr += delta;

		/* If there is recv_reduction due to earlier window_size
       	   reduction, we have to adjust it too. */
		recv_reduction_delta = min(recv_reduction_ptr, delta);

		recv_reduction_ptr -= recv_reduction_delta;

		if (recv_window_size_ptr < 0) {
			recv_window_size_ptr += recv_reduction_delta;
		} else {
			/* If recv_window_size_ptr > 0, then those bytes are going to
		       be returned to the remote peer (by WINDOW_UPDATE with the
		       adjusted delta_ptr), so it is effectively 0 now.  We set to
		       recv_reduction_delta, because caller does not take into
		       account it in delta_ptr. */
			recv_window_size_ptr = recv_reduction_delta;
		}

		/* recv_reduction_delta must be paied from delta_ptr, since it
       	   was added in window size reduction (see below). */
		delta_ptr -= recv_reduction_delta;

		return ErrorCode.OK;
	}

	if (local_window_size_ptr + delta_ptr < 0 ||
		recv_window_size_ptr < int.min - delta_ptr ||
		recv_reduction_ptr > int.max + delta_ptr)
	{
		return ErrorCode.FLOW_CONTROL;
	}
	/* Decreasing local window size. Note that we achieve this without
	   noticing to the remote peer. To do this, we cut
	   recv_window_size by -delta. This means that we don't send
	   WINDOW_UPDATE for -delta bytes. */

	local_window_size_ptr += delta_ptr;
	recv_window_size_ptr += delta_ptr;
	recv_reduction_ptr -= delta_ptr;
	delta_ptr = 0;
	
	return ErrorCode.OK;
}

bool shouldSendWindowUpdate(int local_window_size, int recv_window_size) {
	return recv_window_size >= local_window_size / 2;
}

char[] copyToLower(string str) {
	char[] str_copy = cast(char[])Mem.copy(str);

	for (size_t i = 0; i < str_copy.length; i++) {
		size_t idx = cast(size_t) cast(ubyte) str_copy[i];
		str_copy[i] = DOWNCASE_TBL[idx];
	}

	return str_copy;
}

/* Generated by gendowncasetbl.py */
immutable char[] DOWNCASE_TBL = [
	0 /* NUL  */,   1 /* SOH  */,   2 /* STX  */,   3 /* ETX  */,
	4 /* EOT  */,   5 /* ENQ  */,   6 /* ACK  */,   7 /* BEL  */,
	8 /* BS   */,   9 /* HT   */,   10 /* LF   */,  11 /* VT   */,
	12 /* FF   */,  13 /* CR   */,  14 /* SO   */,  15 /* SI   */,
	16 /* DLE  */,  17 /* DC1  */,  18 /* DC2  */,  19 /* DC3  */,
	20 /* DC4  */,  21 /* NAK  */,  22 /* SYN  */,  23 /* ETB  */,
	24 /* CAN  */,  25 /* EM   */,  26 /* SUB  */,  27 /* ESC  */,
	28 /* FS   */,  29 /* GS   */,  30 /* RS   */,  31 /* US   */,
	32 /* SPC  */,  33 /* !    */,  34 /* "    */,  35 /* #    */,
	36 /* $    */,  37 /* %    */,  38 /* &    */,  39 /* '    */,
	40 /* (    */,  41 /* )    */,  42 /* *    */,  43 /* +    */,
	44 /* ,    */,  45 /* -    */,  46 /* .    */,  47 /* /    */,
	48 /* 0    */,  49 /* 1    */,  50 /* 2    */,  51 /* 3    */,
	52 /* 4    */,  53 /* 5    */,  54 /* 6    */,  55 /* 7    */,
	56 /* 8    */,  57 /* 9    */,  58 /* :    */,  59 /* ;    */,
	60 /* <    */,  61 /* =    */,  62 /* >    */,  63 /* ?    */,
	64 /* @    */,  97 /* A    */,  98 /* B    */,  99 /* C    */,
	100 /* D    */, 101 /* E    */, 102 /* F    */, 103 /* G    */,
	104 /* H    */, 105 /* I    */, 106 /* J    */, 107 /* K    */,
	108 /* L    */, 109 /* M    */, 110 /* N    */, 111 /* O    */,
	112 /* P    */, 113 /* Q    */, 114 /* R    */, 115 /* S    */,
	116 /* T    */, 117 /* U    */, 118 /* V    */, 119 /* W    */,
	120 /* X    */, 121 /* Y    */, 122 /* Z    */, 91 /* [    */,
	92 /* \    */,  93 /* ]    */,  94 /* ^    */,  95 /* _    */,
	96 /* `    */,  97 /* a    */,  98 /* b    */,  99 /* c    */,
	100 /* d    */, 101 /* e    */, 102 /* f    */, 103 /* g    */,
	104 /* h    */, 105 /* i    */, 106 /* j    */, 107 /* k    */,
	108 /* l    */, 109 /* m    */, 110 /* n    */, 111 /* o    */,
	112 /* p    */, 113 /* q    */, 114 /* r    */, 115 /* s    */,
	116 /* t    */, 117 /* u    */, 118 /* v    */, 119 /* w    */,
	120 /* x    */, 121 /* y    */, 122 /* z    */, 123 /* {    */,
	124 /* |    */, 125 /* }    */, 126 /* ~    */, 127 /* DEL  */,
	128 /* 0x80 */, 129 /* 0x81 */, 130 /* 0x82 */, 131 /* 0x83 */,
	132 /* 0x84 */, 133 /* 0x85 */, 134 /* 0x86 */, 135 /* 0x87 */,
	136 /* 0x88 */, 137 /* 0x89 */, 138 /* 0x8a */, 139 /* 0x8b */,
	140 /* 0x8c */, 141 /* 0x8d */, 142 /* 0x8e */, 143 /* 0x8f */,
	144 /* 0x90 */, 145 /* 0x91 */, 146 /* 0x92 */, 147 /* 0x93 */,
	148 /* 0x94 */, 149 /* 0x95 */, 150 /* 0x96 */, 151 /* 0x97 */,
	152 /* 0x98 */, 153 /* 0x99 */, 154 /* 0x9a */, 155 /* 0x9b */,
	156 /* 0x9c */, 157 /* 0x9d */, 158 /* 0x9e */, 159 /* 0x9f */,
	160 /* 0xa0 */, 161 /* 0xa1 */, 162 /* 0xa2 */, 163 /* 0xa3 */,
	164 /* 0xa4 */, 165 /* 0xa5 */, 166 /* 0xa6 */, 167 /* 0xa7 */,
	168 /* 0xa8 */, 169 /* 0xa9 */, 170 /* 0xaa */, 171 /* 0xab */,
	172 /* 0xac */, 173 /* 0xad */, 174 /* 0xae */, 175 /* 0xaf */,
	176 /* 0xb0 */, 177 /* 0xb1 */, 178 /* 0xb2 */, 179 /* 0xb3 */,
	180 /* 0xb4 */, 181 /* 0xb5 */, 182 /* 0xb6 */, 183 /* 0xb7 */,
	184 /* 0xb8 */, 185 /* 0xb9 */, 186 /* 0xba */, 187 /* 0xbb */,
	188 /* 0xbc */, 189 /* 0xbd */, 190 /* 0xbe */, 191 /* 0xbf */,
	192 /* 0xc0 */, 193 /* 0xc1 */, 194 /* 0xc2 */, 195 /* 0xc3 */,
	196 /* 0xc4 */, 197 /* 0xc5 */, 198 /* 0xc6 */, 199 /* 0xc7 */,
	200 /* 0xc8 */, 201 /* 0xc9 */, 202 /* 0xca */, 203 /* 0xcb */,
	204 /* 0xcc */, 205 /* 0xcd */, 206 /* 0xce */, 207 /* 0xcf */,
	208 /* 0xd0 */, 209 /* 0xd1 */, 210 /* 0xd2 */, 211 /* 0xd3 */,
	212 /* 0xd4 */, 213 /* 0xd5 */, 214 /* 0xd6 */, 215 /* 0xd7 */,
	216 /* 0xd8 */, 217 /* 0xd9 */, 218 /* 0xda */, 219 /* 0xdb */,
	220 /* 0xdc */, 221 /* 0xdd */, 222 /* 0xde */, 223 /* 0xdf */,
	224 /* 0xe0 */, 225 /* 0xe1 */, 226 /* 0xe2 */, 227 /* 0xe3 */,
	228 /* 0xe4 */, 229 /* 0xe5 */, 230 /* 0xe6 */, 231 /* 0xe7 */,
	232 /* 0xe8 */, 233 /* 0xe9 */, 234 /* 0xea */, 235 /* 0xeb */,
	236 /* 0xec */, 237 /* 0xed */, 238 /* 0xee */, 239 /* 0xef */,
	240 /* 0xf0 */, 241 /* 0xf1 */, 242 /* 0xf2 */, 243 /* 0xf3 */,
	244 /* 0xf4 */, 245 /* 0xf5 */, 246 /* 0xf6 */, 247 /* 0xf7 */,
	248 /* 0xf8 */, 249 /* 0xf9 */, 250 /* 0xfa */, 251 /* 0xfb */,
	252 /* 0xfc */, 253 /* 0xfd */, 254 /* 0xfe */, 255 /* 0xff */
];


char downcase(char c) {
	return cast(char)('A' <= c && c <= 'Z' ? (c - 'A' + 'a') : c);
}

bool memieq(const void *a, const void *b, size_t n) {
	size_t i;
	const ubyte* aa = cast(const ubyte*) a;
	const ubyte* bb =  cast(const ubyte*) b;
	
	for (i = 0; i < n; ++i) {
		if (downcase(aa[i]) != downcase(bb[i])) {
			return false;
		}
	}
	return true;
}