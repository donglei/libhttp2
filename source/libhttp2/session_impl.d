﻿module libhttp2.session_impl;

/*
 * nghttp2 - HTTP/2 C Library
 *
 * Copyright (c) 2012 Tatsuhiro Tsujikawa
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

static int session_detect_idle_stream(http2_session *session,
    int stream_id) {
    /* Assume that stream object with stream_id does not exist */
    if (http2_session_is_my_stream_id(session, stream_id)) {
        if (session.next_stream_id <= cast(uint)stream_id) {
            return 1;
        }
        return 0;
    }
    if (session_is_new_peer_stream_id(session, stream_id)) {
        return 1;
    }
    return 0;
}

static int session_terminate_session(http2_session *session,
    int last_stream_id,
    uint error_code, const char *reason) {
    int rv;
    const ubyte *debug_data;
    size_t debug_datalen;
    
    if (session.goaway_flags & http2_GOAWAY_TERM_ON_SEND) {
        return 0;
    }
    
    if (reason == NULL) {
        debug_data = NULL;
        debug_datalen = 0;
    } else {
        debug_data = (const ubyte *)reason;
        debug_datalen = strlen(reason);
    }
    
    rv = http2_session_add_goaway(session, last_stream_id, error_code,
        debug_data, debug_datalen,
        http2_GOAWAY_AUX_TERM_ON_SEND);
    
    if (rv != 0) {
        return rv;
    }
    
    session.goaway_flags |= http2_GOAWAY_TERM_ON_SEND;
    
    return 0;
}

int http2_session_terminate_session(http2_session *session,
    uint error_code) {
    return session_terminate_session(session, session.last_proc_stream_id,
        error_code, NULL);
}

int http2_session_terminate_session2(http2_session *session,
    int last_stream_id,
    uint error_code) {
    return session_terminate_session(session, last_stream_id, error_code, NULL);
}

int http2_session_terminate_session_with_reason(http2_session *session,
    uint error_code,
    const char *reason) {
    return session_terminate_session(session, session.last_proc_stream_id,
        error_code, reason);
}

int http2_session_is_my_stream_id(http2_session *session,
    int stream_id) {
    int rem;
    if (stream_id == 0) {
        return 0;
    }
    rem = stream_id & 0x1;
    if (session.server) {
        return rem == 0;
    }
    return rem == 1;
}

http2_stream *http2_session_get_stream(http2_session *session,
    int stream_id) {
    http2_stream *stream;
    
    stream = (http2_stream *)http2_map_find(&session.streams, stream_id);
    
    if (stream == NULL || (stream.flags & http2_STREAM_FLAG_CLOSED) ||
        stream.state == http2_STREAM_IDLE) {
        return NULL;
    }
    
    return stream;
}

http2_stream *http2_session_get_stream_raw(http2_session *session,
    int stream_id) {
    return (http2_stream *)http2_map_find(&session.streams, stream_id);
}

static int outbound_item_compar(const void *lhsx, const void *rhsx) {
    const http2_outbound_item *lhs, *rhs;
    
    lhs = (const http2_outbound_item *)lhsx;
    rhs = (const http2_outbound_item *)rhsx;
    
    if (lhs.cycle == rhs.cycle) {
        if (lhs.weight == rhs.weight) {
            return (lhs.seq < rhs.seq) ? -1 : ((lhs.seq > rhs.seq) ? 1 : 0);
        }
        
        /* Larger weight has higher precedence */
        return rhs.weight - lhs.weight;
    }
    
    return (lhs.cycle < rhs.cycle) ? -1 : 1;
}

static void session_inbound_frame_reset(http2_session *session) {
    http2_inbound_frame *iframe = &session.iframe;
    http2_mem *mem = &session.mem;
    /* A bit risky code, since if this function is called from
     http2_session_new(), we rely on the fact that
     iframe.frame.hd.type is 0, so that no free is performed. */
    switch (iframe.frame.hd.type) {
        case http2_HEADERS:
            http2_frame_headers_free(&iframe.frame.headers, mem);
            break;
        case http2_PRIORITY:
            http2_frame_priority_free(&iframe.frame.priority);
            break;
        case http2_RST_STREAM:
            http2_frame_rst_stream_free(&iframe.frame.rst_stream);
            break;
        case http2_SETTINGS:
            http2_frame_settings_free(&iframe.frame.settings, mem);
            break;
        case http2_PUSH_PROMISE:
            http2_frame_push_promise_free(&iframe.frame.push_promise, mem);
            break;
        case http2_PING:
            http2_frame_ping_free(&iframe.frame.ping);
            break;
        case http2_GOAWAY:
            http2_frame_goaway_free(&iframe.frame.goaway, mem);
            break;
        case http2_WINDOW_UPDATE:
            http2_frame_window_update_free(&iframe.frame.window_update);
            break;
    }
    
    memset(&iframe.frame, 0, sizeof(http2_frame));
    memset(&iframe.ext_frame_payload, 0, sizeof(http2_ext_frame_payload));
    
    iframe.state = http2_IB_READ_HEAD;
    
    http2_buf_wrap_init(&iframe.sbuf, iframe.raw_sbuf,
        sizeof(iframe.raw_sbuf));
    iframe.sbuf.mark += http2_FRAME_HDLEN;
    
    http2_buf_free(&iframe.lbuf, mem);
    http2_buf_wrap_init(&iframe.lbuf, NULL, 0);
    
    iframe.niv = 0;
    iframe.payloadleft = 0;
    iframe.padlen = 0;
    iframe.iv[http2_INBOUND_NUM_IV - 1].settings_id =
        http2_SETTINGS_HEADER_TABLE_SIZE;
    iframe.iv[http2_INBOUND_NUM_IV - 1].value = UINT32_MAX;
}

static void init_settings(http2_settings_storage *settings) {
    settings.header_table_size = http2_HD_DEFAULT_MAX_BUFFER_SIZE;
    settings.enable_push = 1;
    settings.max_concurrent_streams = http2_INITIAL_MAX_CONCURRENT_STREAMS;
    settings.initial_window_size = http2_INITIAL_WINDOW_SIZE;
    settings.max_frame_size = http2_MAX_FRAME_SIZE_MIN;
    settings.max_header_list_size = UINT32_MAX;
}

static void active_outbound_item_reset(http2_active_outbound_item *aob,
    http2_mem *mem) {
    DEBUGF(fprintf(stderr, "send: reset http2_active_outbound_item\n"));
    DEBUGF(fprintf(stderr, "send: aob.item = %p\n", aob.item));
    http2_outbound_item_free(aob.item, mem);
    http2_mem_free(mem, aob.item);
    aob.item = NULL;
    http2_bufs_reset(&aob.framebufs);
    aob.state = http2_OB_POP_ITEM;
}

/* This global variable exists for tests where we want to disable this
   check. */
int http2_enable_strict_first_settings_check = 1;

static int session_new(http2_session **session_ptr,
    const http2_session_callbacks *callbacks,
    void *user_data, int server,
    const http2_option *option, http2_mem *mem) {
    int rv;
    
    if (mem == NULL) {
        mem = http2_mem_default();
    }
    
    *session_ptr = http2_mem_calloc(mem, 1, sizeof(http2_session));
    if (*session_ptr == NULL) {
        rv = ErrorCode.NOMEM;
        goto fail_session;
    }
    
    (*session_ptr).mem = *mem;
    mem = &(*session_ptr).mem;
    
    /* next_stream_id is initialized in either
     http2_session_client_new2 or http2_session_server_new2 */
    
    rv = http2_pq_init(&(*session_ptr).ob_pq, outbound_item_compar, mem);
    if (rv != 0) {
        goto fail_ob_pq;
    }
    rv = http2_pq_init(&(*session_ptr).ob_ss_pq, outbound_item_compar, mem);
    if (rv != 0) {
        goto fail_ob_ss_pq;
    }
    rv = http2_pq_init(&(*session_ptr).ob_da_pq, outbound_item_compar, mem);
    if (rv != 0) {
        goto fail_ob_da_pq;
    }
    
    rv = http2_hd_deflate_init(&(*session_ptr).hd_deflater, mem);
    if (rv != 0) {
        goto fail_hd_deflater;
    }
    rv = http2_hd_inflate_init(&(*session_ptr).hd_inflater, mem);
    if (rv != 0) {
        goto fail_hd_inflater;
    }
    rv = http2_map_init(&(*session_ptr).streams, mem);
    if (rv != 0) {
        goto fail_map;
    }
    
    http2_stream_roots_init(&(*session_ptr).roots);
    
    (*session_ptr).next_seq = 0;
    (*session_ptr).last_cycle = 1;
    
    (*session_ptr).remote_window_size = http2_INITIAL_CONNECTION_WINDOW_SIZE;
    (*session_ptr).recv_window_size = 0;
    (*session_ptr).consumed_size = 0;
    (*session_ptr).recv_reduction = 0;
    (*session_ptr).local_window_size = http2_INITIAL_CONNECTION_WINDOW_SIZE;
    
    (*session_ptr).goaway_flags = http2_GOAWAY_NONE;
    (*session_ptr).local_last_stream_id = (1u << 31) - 1;
    (*session_ptr).remote_last_stream_id = (1u << 31) - 1;
    
    (*session_ptr).inflight_niv = -1;
    
    (*session_ptr).pending_local_max_concurrent_stream =
        http2_INITIAL_MAX_CONCURRENT_STREAMS;
    
    if (server) {
        (*session_ptr).server = 1;
    }
    
    /* 1 for Pad Field. */
    rv = http2_bufs_init3(&(*session_ptr).aob.framebufs,
        http2_FRAMEBUF_CHUNKLEN, http2_FRAMEBUF_MAX_NUM,
        1, http2_FRAME_HDLEN + 1, mem);
    if (rv != 0) {
        goto fail_aob_framebuf;
    }
    
    active_outbound_item_reset(&(*session_ptr).aob, mem);
    
    init_settings(&(*session_ptr).remote_settings);
    init_settings(&(*session_ptr).local_settings);
    
    if (option) {
        if ((option.opt_set_mask & http2_OPT_NO_AUTO_WINDOW_UPDATE) &&
            option.no_auto_window_update) {
            
            (*session_ptr).opt_flags |= http2_OPTMASK_NO_AUTO_WINDOW_UPDATE;
        }
        
        if (option.opt_set_mask & http2_OPT_PEER_MAX_CONCURRENT_STREAMS) {
            
            (*session_ptr).remote_settings.max_concurrent_streams =
                option.peer_max_concurrent_streams;
        }
        
        if ((option.opt_set_mask & http2_OPT_RECV_CLIENT_PREFACE) &&
            option.recv_client_preface) {
            
            (*session_ptr).opt_flags |= http2_OPTMASK_RECV_CLIENT_PREFACE;
        }
        
        if ((option.opt_set_mask & http2_OPT_NO_HTTP_MESSAGING) &&
            option.no_http_messaging) {
            
            (*session_ptr).opt_flags |= http2_OPTMASK_NO_HTTP_MESSAGING;
        }
    }
    
    (*session_ptr).callbacks = *callbacks;
    (*session_ptr).user_data = user_data;
    
    session_inbound_frame_reset(*session_ptr);
    
    if (server &&
        ((*session_ptr).opt_flags & http2_OPTMASK_RECV_CLIENT_PREFACE)) {
        
        http2_inbound_frame *iframe = &(*session_ptr).iframe;
        
        iframe.state = http2_IB_READ_CLIENT_PREFACE;
        iframe.payloadleft = http2_CLIENT_CONNECTION_PREFACE_LEN;
    } else if (http2_enable_strict_first_settings_check) {
        http2_inbound_frame *iframe = &(*session_ptr).iframe;
        
        iframe.state = http2_IB_READ_FIRST_SETTINGS;
    }
    
    return 0;
    
fail_aob_framebuf:
    http2_map_free(&(*session_ptr).streams);
fail_map:
    http2_hd_inflate_free(&(*session_ptr).hd_inflater);
fail_hd_inflater:
    http2_hd_deflate_free(&(*session_ptr).hd_deflater);
fail_hd_deflater:
    http2_pq_free(&(*session_ptr).ob_da_pq);
fail_ob_da_pq:
    http2_pq_free(&(*session_ptr).ob_ss_pq);
fail_ob_ss_pq:
    http2_pq_free(&(*session_ptr).ob_pq);
fail_ob_pq:
    http2_mem_free(mem, *session_ptr);
fail_session:
    return rv;
}

int http2_session_client_new(http2_session **session_ptr,
    const http2_session_callbacks *callbacks,
    void *user_data) {
    return http2_session_client_new3(session_ptr, callbacks, user_data, NULL,
        NULL);
}

int http2_session_client_new2(http2_session **session_ptr,
    const http2_session_callbacks *callbacks,
    void *user_data, const http2_option *option) {
    return http2_session_client_new3(session_ptr, callbacks, user_data, option,
        NULL);
}

int http2_session_client_new3(http2_session **session_ptr,
    const http2_session_callbacks *callbacks,
    void *user_data, const http2_option *option,
    http2_mem *mem) {
    int rv;
    http2_session *session;
    
    rv = session_new(&session, callbacks, user_data, 0, option, mem);
    
    if (rv != 0) {
        return rv;
    }
    /* IDs for use in client */
    session.next_stream_id = 1;
    
    *session_ptr = session;
    
    return 0;
}

int http2_session_server_new(http2_session **session_ptr,
    const http2_session_callbacks *callbacks,
    void *user_data) {
    return http2_session_server_new3(session_ptr, callbacks, user_data, NULL,
        NULL);
}

int http2_session_server_new2(http2_session **session_ptr,
    const http2_session_callbacks *callbacks,
    void *user_data, const http2_option *option) {
    return http2_session_server_new3(session_ptr, callbacks, user_data, option,
        NULL);
}

int http2_session_server_new3(http2_session **session_ptr,
    const http2_session_callbacks *callbacks,
    void *user_data, const http2_option *option,
    http2_mem *mem) {
    int rv;
    http2_session *session;
    
    rv = session_new(&session, callbacks, user_data, 1, option, mem);
    
    if (rv != 0) {
        return rv;
    }
    /* IDs for use in client */
    session.next_stream_id = 2;
    
    *session_ptr = session;
    
    return 0;
}

static int free_streams(http2_map_entry *entry, void *ptr) {
    http2_session *session;
    http2_stream *stream;
    http2_outbound_item *item;
    http2_mem *mem;
    
    session = (http2_session *)ptr;
    mem = &session.mem;
    stream = (http2_stream *)entry;
    item = stream.item;
    
    if (item && !item.queued && item != session.aob.item) {
        http2_outbound_item_free(item, mem);
        http2_mem_free(mem, item);
    }
    
    http2_stream_free(stream);
    http2_mem_free(mem, stream);
    
    return 0;
}

static void ob_pq_free(http2_pq *pq, http2_mem *mem) {
    while (!http2_pq_empty(pq)) {
        http2_outbound_item *item = (http2_outbound_item *)http2_pq_top(pq);
        http2_outbound_item_free(item, mem);
        http2_mem_free(mem, item);
        http2_pq_pop(pq);
    }
    http2_pq_free(pq);
}

void http2_session_del(http2_session *session) {
    http2_mem *mem;
    
    if (session == NULL) {
        return;
    }
    
    mem = &session.mem;
    
    http2_mem_free(mem, session.inflight_iv);
    
    http2_stream_roots_free(&session.roots);
    
    /* Have to free streams first, so that we can check
     stream.item.queued */
    http2_map_each_free(&session.streams, free_streams, session);
    http2_map_free(&session.streams);
    
    ob_pq_free(&session.ob_pq, mem);
    ob_pq_free(&session.ob_ss_pq, mem);
    ob_pq_free(&session.ob_da_pq, mem);
    active_outbound_item_reset(&session.aob, mem);
    session_inbound_frame_reset(session);
    http2_hd_deflate_free(&session.hd_deflater);
    http2_hd_inflate_free(&session.hd_inflater);
    http2_bufs_free(&session.aob.framebufs);
    http2_mem_free(mem, session);
}

int
    http2_session_reprioritize_stream(http2_session *session,
        http2_stream *stream,
const http2_priority_spec *pri_spec_in) {
    int rv;
    http2_stream *dep_stream = NULL;
    http2_stream *root_stream;
    http2_priority_spec pri_spec_default;
    const http2_priority_spec *pri_spec = pri_spec_in;
    
    if (!http2_stream_in_dep_tree(stream)) {
        return 0;
    }
    
    if (pri_spec.stream_id == stream.stream_id) {
        return http2_session_terminate_session_with_reason(
            session, http2_PROTOCOL_ERROR, "depend on itself");
    }
    
    if (pri_spec.stream_id != 0) {
        dep_stream = http2_session_get_stream_raw(session, pri_spec.stream_id);
        
        if (session.server && !dep_stream &&
            session_detect_idle_stream(session, pri_spec.stream_id)) {
            
            http2_priority_spec_default_init(&pri_spec_default);
            
            dep_stream = http2_session_open_stream(
                session, pri_spec.stream_id, http2_FLAG_NONE, &pri_spec_default,
                http2_STREAM_IDLE, NULL);
            
            if (dep_stream == NULL) {
                return ErrorCode.NOMEM;
            }
        } else if (!dep_stream || !http2_stream_in_dep_tree(dep_stream)) {
            http2_priority_spec_default_init(&pri_spec_default);
            pri_spec = &pri_spec_default;
        }
    }
    
    if (pri_spec.stream_id == 0) {
        http2_stream_dep_remove_subtree(stream);
        
        /* We have to update weight after removing stream from tree */
        stream.weight = pri_spec.weight;
        
        if (pri_spec.exclusive &&
            session.roots.num_streams <= http2_MAX_DEP_TREE_LENGTH) {
            
            rv = http2_stream_dep_all_your_stream_are_belong_to_us(stream, session);
        } else {
            rv = http2_stream_dep_make_root(stream, session);
        }
        
        return rv;
    }
    
    assert(dep_stream);
    
    if (http2_stream_dep_subtree_find(stream, dep_stream)) {
        DEBUGF(fprintf(stderr, "stream: cycle detected, dep_stream(%p)=%d "
                "stream(%p)=%d\n",
                dep_stream, dep_stream.stream_id, stream,
                stream.stream_id));
        
        http2_stream_dep_remove_subtree(dep_stream);
        http2_stream_dep_make_root(dep_stream, session);
    }
    
    http2_stream_dep_remove_subtree(stream);
    
    /* We have to update weight after removing stream from tree */
    stream.weight = pri_spec.weight;
    
    root_stream = http2_stream_get_dep_root(dep_stream);
    
    if (root_stream.num_substreams + stream.num_substreams >
        http2_MAX_DEP_TREE_LENGTH) {
        stream.weight = http2_DEFAULT_WEIGHT;
        
        rv = http2_stream_dep_make_root(stream, session);
    } else {
        if (pri_spec.exclusive) {
            rv = http2_stream_dep_insert_subtree(dep_stream, stream, session);
        } else {
            rv = http2_stream_dep_add_subtree(dep_stream, stream, session);
        }
    }
    
    if (rv != 0) {
        return rv;
    }
    
    return 0;
}

void http2_session_outbound_item_init(http2_session *session,
    http2_outbound_item *item) {
    item.seq = session.next_seq++;
    /* We use cycle for DATA only */
    item.cycle = 0;
    item.weight = http2_OB_EX_WEIGHT;
    item.queued = 0;
    
    memset(&item.aux_data, 0, sizeof(http2_aux_data));
}

int http2_session_add_item(http2_session *session,
    http2_outbound_item *item) {
    /* TODO Return error if stream is not found for the frame requiring
     stream presence. */
    int rv = 0;
    http2_stream *stream;
    http2_frame *frame;
    
    frame = &item.frame;
    stream = http2_session_get_stream(session, frame.hd.stream_id);
    
    if (frame.hd.type != http2_DATA) {
        
        switch (frame.hd.type) {
            case http2_RST_STREAM:
                if (stream) {
                    stream.state = http2_STREAM_CLOSING;
                }
                
                break;
            case http2_SETTINGS:
                item.weight = http2_OB_SETTINGS_WEIGHT;
                
                break;
            case http2_PING:
                /* Ping has highest priority. */
                item.weight = http2_OB_PING_WEIGHT;
                
                break;
            default:
                break;
        }
        
        if (frame.hd.type == http2_HEADERS) {
            /* We push request HEADERS and push response HEADERS to
         dedicated queue because their transmission is affected by
         SETTINGS_MAX_CONCURRENT_STREAMS */
            /* TODO If 2 HEADERS are submitted for reserved stream, then
         both of them are queued into ob_ss_pq, which is not
         desirable. */
            if (frame.headers.cat == http2_HCAT_REQUEST) {
                rv = http2_pq_push(&session.ob_ss_pq, item);
                
                if (rv != 0) {
                    return rv;
                }
                
                item.queued = 1;
            } else if (stream && (stream.state == http2_STREAM_RESERVED ||
                    item.aux_data.headers.attach_stream)) {
                item.weight = stream.effective_weight;
                item.cycle = session.last_cycle;
                
                rv = http2_stream_attach_item(stream, item, session);
                
                if (rv != 0) {
                    return rv;
                }
            } else {
                rv = http2_pq_push(&session.ob_pq, item);
                
                if (rv != 0) {
                    return rv;
                }
                
                item.queued = 1;
            }
        } else {
            rv = http2_pq_push(&session.ob_pq, item);
            
            if (rv != 0) {
                return rv;
            }
            
            item.queued = 1;
        }
        
        return 0;
    }
    
    if (!stream) {
        return ErrorCode.STREAM_CLOSED;
    }
    
    if (stream.item) {
        return ErrorCode.DATA_EXIST;
    }
    
    item.weight = stream.effective_weight;
    item.cycle = session.last_cycle;
    
    rv = http2_stream_attach_item(stream, item, session);
    
    if (rv != 0) {
        return rv;
    }
    
    return 0;
}

struct http2_rst_target {
    int stream_id;
    uint error_code;
}

static int cancel_pending_request(void *pq_item, void *arg) {
    http2_outbound_item *item;
    http2_rst_target *t;
    http2_headers_aux_data *aux_data;
    
    item = pq_item;
    t = arg;
    aux_data = &item.aux_data.headers;
    
    if (item.frame.hd.stream_id != t.stream_id || aux_data.canceled) {
        return 0;
    }
    
    aux_data.error_code = t.error_code;
    aux_data.canceled = 1;
    
    return 1;
}

int http2_session_add_rst_stream(http2_session *session, int stream_id,
    uint error_code) {
    int rv;
    http2_outbound_item *item;
    http2_frame *frame;
    http2_stream *stream;
    http2_mem *mem;
    http2_rst_target t = {stream_id, error_code};
    
    mem = &session.mem;
    stream = http2_session_get_stream(session, stream_id);
    if (stream && stream.state == http2_STREAM_CLOSING) {
        return 0;
    }
    
    /* Cancel pending request HEADERS in ob_ss_pq if this RST_STREAM
     refers to that stream. */
    if (!session.server && http2_session_is_my_stream_id(session, stream_id) &&
        http2_pq_top(&session.ob_ss_pq)) {
        http2_outbound_item *top;
        http2_frame *headers_frame;
        
        top = http2_pq_top(&session.ob_ss_pq);
        headers_frame = &top.frame;
        
        assert(headers_frame.hd.type == http2_HEADERS);
        
        if (headers_frame.hd.stream_id <= stream_id &&
            cast(uint)stream_id < session.next_stream_id) {
            if (http2_pq_each(&session.ob_ss_pq, cancel_pending_request, &t)) {
                return 0;
            }
        }
    }
    
    item = http2_mem_malloc(mem, sizeof(http2_outbound_item));
    if (item == NULL) {
        return ErrorCode.NOMEM;
    }
    
    http2_session_outbound_item_init(session, item);
    
    frame = &item.frame;
    
    http2_frame_rst_stream_init(&frame.rst_stream, stream_id, error_code);
    rv = http2_session_add_item(session, item);
    if (rv != 0) {
        http2_frame_rst_stream_free(&frame.rst_stream);
        http2_mem_free(mem, item);
        return rv;
    }
    return 0;
}

http2_stream *http2_session_open_stream(http2_session *session,
    int stream_id, ubyte flags,
    http2_priority_spec *pri_spec_in,
    http2_stream_state initial_state,
    void *stream_user_data) {
    int rv;
    http2_stream *stream;
    http2_stream *dep_stream = NULL;
    http2_stream *root_stream;
    int stream_alloc = 0;
    http2_priority_spec pri_spec_default;
    http2_priority_spec *pri_spec = pri_spec_in;
    http2_mem *mem;
    
    mem = &session.mem;
    stream = http2_session_get_stream_raw(session, stream_id);
    
    if (stream) {
        assert(stream.state == http2_STREAM_IDLE);
        assert(http2_stream_in_dep_tree(stream));
        http2_session_detach_idle_stream(session, stream);
        http2_stream_dep_remove(stream);
    } else {
        if (session.server && initial_state != http2_STREAM_IDLE &&
            !http2_session_is_my_stream_id(session, stream_id)) {
            
            http2_session_adjust_closed_stream(session, 1);
        }
        
        stream = http2_mem_malloc(mem, sizeof(http2_stream));
        if (stream == NULL) {
            return NULL;
        }
        
        stream_alloc = 1;
    }
    
    if (pri_spec.stream_id != 0) {
        dep_stream = http2_session_get_stream_raw(session, pri_spec.stream_id);
        
        if (session.server && !dep_stream &&
            session_detect_idle_stream(session, pri_spec.stream_id)) {
            /* Depends on idle stream, which does not exist in memory.
         Assign default priority for it. */
            http2_priority_spec_default_init(&pri_spec_default);
            
            dep_stream = http2_session_open_stream(
                session, pri_spec.stream_id, http2_FLAG_NONE, &pri_spec_default,
                http2_STREAM_IDLE, NULL);
            
            if (dep_stream == NULL) {
                if (stream_alloc) {
                    http2_mem_free(mem, stream);
                }
                
                return NULL;
            }
        } else if (!dep_stream || !http2_stream_in_dep_tree(dep_stream)) {
            /* If dep_stream is not part of dependency tree, stream will get
         default priority. */
            http2_priority_spec_default_init(&pri_spec_default);
            pri_spec = &pri_spec_default;
        }
    }
    
    if (initial_state == http2_STREAM_RESERVED) {
        flags |= http2_STREAM_FLAG_PUSH;
    }
    
    http2_stream_init(
        stream, stream_id, flags, initial_state, pri_spec.weight,
        &session.roots, session.remote_settings.initial_window_size,
        session.local_settings.initial_window_size, stream_user_data);
    
    if (stream_alloc) {
        rv = http2_map_insert(&session.streams, &stream.map_entry);
        if (rv != 0) {
            http2_mem_free(mem, stream);
            return NULL;
        }
    }
    
    switch (initial_state) {
        case http2_STREAM_RESERVED:
            if (http2_session_is_my_stream_id(session, stream_id)) {
                /* half closed (remote) */
                http2_stream_shutdown(stream, http2_SHUT_RD);
            } else {
                /* half closed (local) */
                http2_stream_shutdown(stream, http2_SHUT_WR);
            }
            /* Reserved stream does not count in the concurrent streams
       limit. That is one of the DOS vector. */
            break;
        case http2_STREAM_IDLE:
            /* Idle stream does not count toward the concurrent streams limit.
       This is used as anchor node in dependency tree. */
            assert(session.server);
            http2_session_keep_idle_stream(session, stream);
            break;
        default:
            if (http2_session_is_my_stream_id(session, stream_id)) {
                ++session.num_outgoing_streams;
            } else {
                ++session.num_incoming_streams;
            }
    }
    
    /* We don't have to track dependency of received reserved stream */
    if (stream.shut_flags & http2_SHUT_WR) {
        return stream;
    }
    
    if (pri_spec.stream_id == 0) {
        
        ++session.roots.num_streams;
        
        if (pri_spec.exclusive &&
            session.roots.num_streams <= http2_MAX_DEP_TREE_LENGTH) {
            rv = http2_stream_dep_all_your_stream_are_belong_to_us(stream, session);
            
            /* Since no dpri is changed in dependency tree, the above
         function call never fail. */
            assert(rv == 0);
        } else {
            http2_stream_roots_add(&session.roots, stream);
        }
        
        return stream;
    }
    
    /* TODO Client does not have to track dependencies of streams except
     for those which have upload data.  Currently, we just track
     everything. */
    
    assert(dep_stream);
    
    root_stream = http2_stream_get_dep_root(dep_stream);
    
    if (root_stream.num_substreams < http2_MAX_DEP_TREE_LENGTH) {
        if (pri_spec.exclusive) {
            http2_stream_dep_insert(dep_stream, stream);
        } else {
            http2_stream_dep_add(dep_stream, stream);
        }
    } else {
        stream.weight = http2_DEFAULT_WEIGHT;
        
        http2_stream_roots_add(&session.roots, stream);
    }
    
    return stream;
}

int http2_session_close_stream(http2_session *session, int stream_id,
    uint error_code) {
    int rv;
    http2_stream *stream;
    http2_mem *mem;
    
    mem = &session.mem;
    stream = http2_session_get_stream(session, stream_id);
    
    if (!stream) {
        return ErrorCode.INVALID_ARGUMENT;
    }
    
    DEBUGF(fprintf(stderr, "stream: stream(%p)=%d close\n", stream,
            stream.stream_id));
    
    if (stream.item) {
        http2_outbound_item *item;
        
        item = stream.item;
        
        rv = http2_stream_detach_item(stream, session);
        
        if (rv != 0) {
            return rv;
        }
        
        /* If item is queued, it will be deleted when it is popped
       (http2_session_prep_frame() will fail).  If session.aob.item
       points to this item, let active_outbound_item_reset()
       free the item. */
        if (!item.queued && item != session.aob.item) {
            http2_outbound_item_free(item, mem);
            http2_mem_free(mem, item);
        }
    }
    
    /* We call on_stream_close_callback even if stream.state is
     http2_STREAM_INITIAL. This will happen while sending request
     HEADERS, a local endpoint receives RST_STREAM for that stream. It
     may be PROTOCOL_ERROR, but without notifying stream closure will
     hang the stream in a local endpoint.
  */
    
    if (session.callbacks.on_stream_close_callback) {
        if (session.callbacks.on_stream_close_callback(
                session, stream_id, error_code, session.user_data) != 0) {
            
            return ErrorCode.CALLBACK_FAILURE;
        }
    }
    
    /* pushed streams which is not opened yet is not counted toward max
     concurrent limits */
    if ((stream.flags & http2_STREAM_FLAG_PUSH) == 0) {
        if (http2_session_is_my_stream_id(session, stream_id)) {
            --session.num_outgoing_streams;
        } else {
            --session.num_incoming_streams;
        }
    }
    
    /* Closes both directions just in case they are not closed yet */
    stream.flags |= http2_STREAM_FLAG_CLOSED;
    
    if (session.server && http2_stream_in_dep_tree(stream)) {
        /* On server side, retain stream at most MAX_CONCURRENT_STREAMS
       combined with the current active incoming streams to make
       dependency tree work better. */
        http2_session_keep_closed_stream(session, stream);
    } else {
        http2_session_destroy_stream(session, stream);
    }
    
    return 0;
}

void http2_session_destroy_stream(http2_session *session,
    http2_stream *stream) {
    http2_mem *mem;
    
    DEBUGF(fprintf(stderr, "stream: destroy closed stream(%p)=%d\n", stream,
            stream.stream_id));
    
    mem = &session.mem;
    
    http2_stream_dep_remove(stream);
    
    http2_map_remove(&session.streams, stream.stream_id);
    http2_stream_free(stream);
    http2_mem_free(mem, stream);
}

void http2_session_keep_closed_stream(http2_session *session,
    http2_stream *stream) {
    DEBUGF(fprintf(stderr, "stream: keep closed stream(%p)=%d, state=%d\n",
            stream, stream.stream_id, stream.state));
    
    if (session.closed_stream_tail) {
        session.closed_stream_tail.closed_next = stream;
        stream.closed_prev = session.closed_stream_tail;
    } else {
        session.closed_stream_head = stream;
    }
    session.closed_stream_tail = stream;
    
    ++session.num_closed_streams;
    
    http2_session_adjust_closed_stream(session, 0);
}

void http2_session_keep_idle_stream(http2_session *session,
    http2_stream *stream) {
    DEBUGF(fprintf(stderr, "stream: keep idle stream(%p)=%d, state=%d\n", stream,
            stream.stream_id, stream.state));
    
    if (session.idle_stream_tail) {
        session.idle_stream_tail.closed_next = stream;
        stream.closed_prev = session.idle_stream_tail;
    } else {
        session.idle_stream_head = stream;
    }
    session.idle_stream_tail = stream;
    
    ++session.num_idle_streams;
    
    http2_session_adjust_idle_stream(session);
}

void http2_session_detach_idle_stream(http2_session *session,
    http2_stream *stream) {
    http2_stream *prev_stream, *next_stream;
    
    DEBUGF(fprintf(stderr, "stream: detach idle stream(%p)=%d, state=%d\n",
            stream, stream.stream_id, stream.state));
    
    prev_stream = stream.closed_prev;
    next_stream = stream.closed_next;
    
    if (prev_stream) {
        prev_stream.closed_next = next_stream;
    } else {
        session.idle_stream_head = next_stream;
    }
    
    if (next_stream) {
        next_stream.closed_prev = prev_stream;
    } else {
        session.idle_stream_tail = prev_stream;
    }
    
    stream.closed_prev = NULL;
    stream.closed_next = NULL;
    
    --session.num_idle_streams;
}

void http2_session_adjust_closed_stream(http2_session *session,
    size_t offset) {
    size_t num_stream_max;
    
    num_stream_max = http2_min(session.local_settings.max_concurrent_streams,
        session.pending_local_max_concurrent_stream);
    
    DEBUGF(fprintf(stderr, "stream: adjusting kept closed streams "
            "num_closed_streams=%zu, num_incoming_streams=%zu, "
            "max_concurrent_streams=%zu\n",
            session.num_closed_streams, session.num_incoming_streams,
            num_stream_max));
    
    while (session.num_closed_streams > 0 &&
        session.num_closed_streams + session.num_incoming_streams + offset >
        num_stream_max) {
        http2_stream *head_stream;
        
        head_stream = session.closed_stream_head;
        
        assert(head_stream);
        
        session.closed_stream_head = head_stream.closed_next;
        
        if (session.closed_stream_head) {
            session.closed_stream_head.closed_prev = NULL;
        } else {
            session.closed_stream_tail = NULL;
        }
        
        http2_session_destroy_stream(session, head_stream);
        /* head_stream is now freed */
        --session.num_closed_streams;
    }
}

void http2_session_adjust_idle_stream(http2_session *session) {
    size_t max;
    
    /* Make minimum number of idle streams 2 so that allocating 2
     streams at once is easy.  This happens when PRIORITY frame to
     idle stream, which depends on idle stream which does not
     exist. */
    max =
        http2_max(2, http2_min(session.local_settings.max_concurrent_streams,
                session.pending_local_max_concurrent_stream));
    
    DEBUGF(fprintf(stderr, "stream: adjusting kept idle streams "
            "num_idle_streams=%zu, max=%zu\n",
            session.num_idle_streams, max));
    
    while (session.num_idle_streams > max) {
        http2_stream *head;
        
        head = session.idle_stream_head;
        assert(head);
        
        session.idle_stream_head = head.closed_next;
        
        if (session.idle_stream_head) {
            session.idle_stream_head.closed_prev = NULL;
        } else {
            session.idle_stream_tail = NULL;
        }
        
        http2_session_destroy_stream(session, head);
        /* head is now destroyed */
        --session.num_idle_streams;
    }
}

/*
 * Closes stream with stream ID |stream_id| if both transmission and
 * reception of the stream were disallowed. The |error_code| indicates
 * the reason of the closure.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.INVALID_ARGUMENT
 *   The stream is not found.
 * ErrorCode.CALLBACK_FAILURE
 *   The callback function failed.
 */
int http2_session_close_stream_if_shut_rdwr(http2_session *session,
    http2_stream *stream) {
    if ((stream.shut_flags & http2_SHUT_RDWR) == http2_SHUT_RDWR) {
        return http2_session_close_stream(session, stream.stream_id,
            http2_NO_ERROR);
    }
    return 0;
}

/*
 * This function returns nonzero if session is closing.
 */
static int session_is_closing(http2_session *session) {
    return (session.goaway_flags & http2_GOAWAY_TERM_ON_SEND) != 0;
}

/*
 * Check that we can send a frame to the |stream|. This function
 * returns 0 if we can send a frame to the |frame|, or one of the
 * following negative error codes:
 *
 * ErrorCode.STREAM_CLOSED
 *   The stream is already closed.
 * ErrorCode.STREAM_SHUT_WR
 *   The stream is half-closed for transmission.
 * ErrorCode.SESSION_CLOSING
 *   This session is closing.
 */
static int session_predicate_for_stream_send(http2_session *session,
    http2_stream *stream) {
    if (stream == NULL) {
        return ErrorCode.STREAM_CLOSED;
    }
    if (session_is_closing(session)) {
        return ErrorCode.SESSION_CLOSING;
    }
    if (stream.shut_flags & http2_SHUT_WR) {
        return ErrorCode.STREAM_SHUT_WR;
    }
    return 0;
}

/*
 * This function checks request HEADERS frame, which opens stream, can
 * be sent at this time.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.START_STREAM_NOT_ALLOWED
 *     New stream cannot be created because of GOAWAY: session is
 *     going down or received last_stream_id is strictly less than
 *     frame.hd.stream_id.
 * ErrorCode.STREAM_CLOSING
 *     request HEADERS was canceled by RST_STREAM while it is in queue.
 */
static int session_predicate_request_headers_send(http2_session *session,
    http2_outbound_item *item) {
    if (item.aux_data.headers.canceled) {
        return ErrorCode.STREAM_CLOSING;
    }
    /* If we are terminating session (http2_GOAWAY_TERM_ON_SEND) or
     GOAWAY was received from peer, new request is not allowed. */
    if (session.goaway_flags &
        (http2_GOAWAY_TERM_ON_SEND | http2_GOAWAY_RECV)) {
        return ErrorCode.START_STREAM_NOT_ALLOWED;
    }
    return 0;
}

/*
 * This function checks HEADERS, which is the first frame from the
 * server, with the |stream| can be sent at this time.  The |stream|
 * can be NULL.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.STREAM_CLOSED
 *     The stream is already closed or does not exist.
 * ErrorCode.STREAM_SHUT_WR
 *     The transmission is not allowed for this stream (e.g., a frame
 *     with END_STREAM flag set has already sent)
 * ErrorCode.INVALID_STREAM_ID
 *     The stream ID is invalid.
 * ErrorCode.STREAM_CLOSING
 *     RST_STREAM was queued for this stream.
 * ErrorCode.INVALID_STREAM_STATE
 *     The state of the stream is not valid.
 * ErrorCode.SESSION_CLOSING
 *   This session is closing.
 */
static int session_predicate_response_headers_send(http2_session *session,
    http2_stream *stream) {
    int rv;
    rv = session_predicate_for_stream_send(session, stream);
    if (rv != 0) {
        return rv;
    }
    assert(stream);
    if (http2_session_is_my_stream_id(session, stream.stream_id)) {
        return ErrorCode.INVALID_STREAM_ID;
    }
    if (stream.state == http2_STREAM_OPENING) {
        return 0;
    }
    if (stream.state == http2_STREAM_CLOSING) {
        return ErrorCode.STREAM_CLOSING;
    }
    return ErrorCode.INVALID_STREAM_STATE;
}

/*
 * This function checks HEADERS for reserved stream can be sent. The
 * |stream| must be reserved state and the |session| is server side.
 * The |stream| can be NULL.
 *
 * This function returns 0 if it succeeds, or one of the following
 * error codes:
 *
 * ErrorCode.STREAM_CLOSED
 *   The stream is already closed.
 * ErrorCode.STREAM_SHUT_WR
 *   The stream is half-closed for transmission.
 * ErrorCode.PROTO
 *   The stream is not reserved state
 * ErrorCode.STREAM_CLOSED
 *   RST_STREAM was queued for this stream.
 * ErrorCode.SESSION_CLOSING
 *   This session is closing.
 */
static int
    session_predicate_push_response_headers_send(http2_session *session,
http2_stream *stream) {
    int rv;
    /* TODO Should disallow HEADERS if GOAWAY has already been issued? */
    rv = session_predicate_for_stream_send(session, stream);
    if (rv != 0) {
        return rv;
    }
    assert(stream);
    if (stream.state != http2_STREAM_RESERVED) {
        return ErrorCode.PROTO;
    }
    if (stream.state == http2_STREAM_CLOSING) {
        return ErrorCode.STREAM_CLOSING;
    }
    return 0;
}

/*
 * This function checks HEADERS, which is neither stream-opening nor
 * first response header, with the |stream| can be sent at this time.
 * The |stream| can be NULL.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.STREAM_CLOSED
 *     The stream is already closed or does not exist.
 * ErrorCode.STREAM_SHUT_WR
 *     The transmission is not allowed for this stream (e.g., a frame
 *     with END_STREAM flag set has already sent)
 * ErrorCode.STREAM_CLOSING
 *     RST_STREAM was queued for this stream.
 * ErrorCode.INVALID_STREAM_STATE
 *     The state of the stream is not valid.
 * ErrorCode.SESSION_CLOSING
 *   This session is closing.
 */
static int session_predicate_headers_send(http2_session *session,
    http2_stream *stream) {
    int rv;
    rv = session_predicate_for_stream_send(session, stream);
    if (rv != 0) {
        return rv;
    }
    assert(stream);
    if (http2_session_is_my_stream_id(session, stream.stream_id)) {
        if (stream.state == http2_STREAM_CLOSING) {
            return ErrorCode.STREAM_CLOSING;
        }
        return 0;
    }
    if (stream.state == http2_STREAM_OPENED) {
        return 0;
    }
    if (stream.state == http2_STREAM_CLOSING) {
        return ErrorCode.STREAM_CLOSING;
    }
    return ErrorCode.INVALID_STREAM_STATE;
}

/*
 * This function checks PUSH_PROMISE frame |frame| with the |stream|
 * can be sent at this time.  The |stream| can be NULL.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.START_STREAM_NOT_ALLOWED
 *     New stream cannot be created because GOAWAY is already sent or
 *     received.
 * ErrorCode.PROTO
 *     The client side attempts to send PUSH_PROMISE, or the server
 *     sends PUSH_PROMISE for the stream not initiated by the client.
 * ErrorCode.STREAM_CLOSED
 *     The stream is already closed or does not exist.
 * ErrorCode.STREAM_CLOSING
 *     RST_STREAM was queued for this stream.
 * ErrorCode.STREAM_SHUT_WR
 *     The transmission is not allowed for this stream (e.g., a frame
 *     with END_STREAM flag set has already sent)
 * ErrorCode.PUSH_DISABLED
 *     The remote peer disabled reception of PUSH_PROMISE.
 * ErrorCode.SESSION_CLOSING
 *   This session is closing.
 */
static int session_predicate_push_promise_send(http2_session *session,
    http2_stream *stream) {
    int rv;
    
    if (!session.server) {
        return ErrorCode.PROTO;
    }
    
    rv = session_predicate_for_stream_send(session, stream);
    if (rv != 0) {
        return rv;
    }
    
    assert(stream);
    
    if (session.remote_settings.enable_push == 0) {
        return ErrorCode.PUSH_DISABLED;
    }
    if (stream.state == http2_STREAM_CLOSING) {
        return ErrorCode.STREAM_CLOSING;
    }
    if (session.goaway_flags & http2_GOAWAY_RECV) {
        return ErrorCode.START_STREAM_NOT_ALLOWED;
    }
    return 0;
}

/*
 * This function checks WINDOW_UPDATE with the stream ID |stream_id|
 * can be sent at this time. Note that END_STREAM flag of the previous
 * frame does not affect the transmission of the WINDOW_UPDATE frame.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.STREAM_CLOSED
 *     The stream is already closed or does not exist.
 * ErrorCode.STREAM_CLOSING
 *     RST_STREAM was queued for this stream.
 * ErrorCode.INVALID_STREAM_STATE
 *     The state of the stream is not valid.
 * ErrorCode.SESSION_CLOSING
 *   This session is closing.
 */
static int session_predicate_window_update_send(http2_session *session,
    int stream_id) {
    http2_stream *stream;
    if (stream_id == 0) {
        /* Connection-level window update */
        return 0;
    }
    stream = http2_session_get_stream(session, stream_id);
    if (stream == NULL) {
        return ErrorCode.STREAM_CLOSED;
    }
    if (session_is_closing(session)) {
        return ErrorCode.SESSION_CLOSING;
    }
    if (stream.state == http2_STREAM_CLOSING) {
        return ErrorCode.STREAM_CLOSING;
    }
    if (state_reserved_local(session, stream)) {
        return ErrorCode.INVALID_STREAM_STATE;
    }
    return 0;
}

/* Take into account settings max frame size and both connection-level
   flow control here */
static size_t
    http2_session_enforce_flow_control_limits(http2_session *session,
        http2_stream *stream,
size_t requested_window_size) {
    DEBUGF(fprintf(stderr, "send: remote windowsize connection=%d, "
            "remote maxframsize=%u, stream(id %d)=%d\n",
            session.remote_window_size,
            session.remote_settings.max_frame_size, stream.stream_id,
            stream.remote_window_size));
    
    return http2_min(http2_min(http2_min(requested_window_size,
                stream.remote_window_size),
            session.remote_window_size),
        (int)session.remote_settings.max_frame_size);
}

/*
 * Returns the maximum length of next data read. If the
 * connection-level and/or stream-wise flow control are enabled, the
 * return value takes into account those current window sizes. The remote
 * settings for max frame size is also taken into account.
 */
static size_t http2_session_next_data_read(http2_session *session,
    http2_stream *stream) {
    size_t window_size;
    
    window_size = http2_session_enforce_flow_control_limits(
        session, stream, http2_DATA_PAYLOADLEN);
    
    DEBUGF(fprintf(stderr, "send: available window=%zd\n", window_size));
    
    return window_size > 0 ? (size_t)window_size : 0;
}

/*
 * This function checks DATA with the |stream| can be sent at this
 * time.  The |stream| can be NULL.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.STREAM_CLOSED
 *     The stream is already closed or does not exist.
 * ErrorCode.STREAM_SHUT_WR
 *     The transmission is not allowed for this stream (e.g., a frame
 *     with END_STREAM flag set has already sent)
 * ErrorCode.STREAM_CLOSING
 *     RST_STREAM was queued for this stream.
 * ErrorCode.INVALID_STREAM_STATE
 *     The state of the stream is not valid.
 * ErrorCode.SESSION_CLOSING
 *   This session is closing.
 */
static int http2_session_predicate_data_send(http2_session *session,
    http2_stream *stream) {
    int rv;
    rv = session_predicate_for_stream_send(session, stream);
    if (rv != 0) {
        return rv;
    }
    assert(stream);
    if (http2_session_is_my_stream_id(session, stream.stream_id)) {
        /* Request body data */
        /* If stream.state is http2_STREAM_CLOSING, RST_STREAM was
       queued but not yet sent. In this case, we won't send DATA
       frames. */
        if (stream.state == http2_STREAM_CLOSING) {
            return ErrorCode.STREAM_CLOSING;
        }
        if (stream.state == http2_STREAM_RESERVED) {
            return ErrorCode.INVALID_STREAM_STATE;
        }
        return 0;
    }
    /* Response body data */
    if (stream.state == http2_STREAM_OPENED) {
        return 0;
    }
    if (stream.state == http2_STREAM_CLOSING) {
        return ErrorCode.STREAM_CLOSING;
    }
    return ErrorCode.INVALID_STREAM_STATE;
}

static size_t session_call_select_padding(http2_session *session,
    const http2_frame *frame,
    size_t max_payloadlen) {
    size_t rv;
    
    if (frame.hd.length >= max_payloadlen) {
        return frame.hd.length;
    }
    
    if (session.callbacks.select_padding_callback) {
        size_t max_paddedlen;
        
        max_paddedlen =
            http2_min(frame.hd.length + http2_MAX_PADLEN, max_payloadlen);
        
        rv = session.callbacks.select_padding_callback(
            session, frame, max_paddedlen, session.user_data);
        if (rv < (size_t)frame.hd.length || rv > (size_t)max_paddedlen) {
            return ErrorCode.CALLBACK_FAILURE;
        }
        return rv;
    }
    return frame.hd.length;
}

/* Add padding to HEADERS or PUSH_PROMISE. We use
   frame.headers.padlen in this function to use the fact that
   frame.push_promise has also padlen in the same position. */
static int session_headers_add_pad(http2_session *session,
    http2_frame *frame) {
    int rv;
    size_t padded_payloadlen;
    http2_active_outbound_item *aob;
    http2_bufs *framebufs;
    size_t padlen;
    size_t max_payloadlen;
    
    aob = &session.aob;
    framebufs = &aob.framebufs;
    
    max_payloadlen = http2_min(http2_MAX_PAYLOADLEN,
        frame.hd.length + http2_MAX_PADLEN);
    
    padded_payloadlen =
        session_call_select_padding(session, frame, max_payloadlen);
    
    if (http2_is_fatal((int)padded_payloadlen)) {
        return (int)padded_payloadlen;
    }
    
    padlen = padded_payloadlen - frame.hd.length;
    
    DEBUGF(fprintf(stderr, "send: padding selected: payloadlen=%zd, padlen=%zu\n",
            padded_payloadlen, padlen));
    
    rv = http2_frame_add_pad(framebufs, &frame.hd, padlen);
    
    if (rv != 0) {
        return rv;
    }
    
    frame.headers.padlen = padlen;
    
    return 0;
}

static size_t session_estimate_headers_payload(http2_session *session,
    const http2_nv *nva,
    size_t nvlen,
    size_t additional) {
    return http2_hd_deflate_bound(&session.hd_deflater, nva, nvlen) +
        additional;
}

/*
 * This function serializes frame for transmission.
 *
 * This function returns 0 if it succeeds, or one of negative error
 * codes, including both fatal and non-fatal ones.
 */
static int session_prep_frame(http2_session *session,
    http2_outbound_item *item) {
    int rv;
    http2_frame *frame;
    http2_mem *mem;
    
    mem = &session.mem;
    frame = &item.frame;
    
    if (frame.hd.type != http2_DATA) {
        switch (frame.hd.type) {
            case http2_HEADERS: {
                http2_headers_aux_data *aux_data;
                size_t estimated_payloadlen;
                
                aux_data = &item.aux_data.headers;
                
                estimated_payloadlen = session_estimate_headers_payload(
                    session, frame.headers.nva, frame.headers.nvlen,
                    http2_PRIORITY_SPECLEN);
                
                if (estimated_payloadlen > http2_MAX_HEADERSLEN) {
                    return ErrorCode.FRAME_SIZE_ERROR;
                }
                
                if (frame.headers.cat == http2_HCAT_REQUEST) {
                    /* initial HEADERS, which opens stream */
                    http2_stream *stream;
                    
                    stream = http2_session_open_stream(
                        session, frame.hd.stream_id, http2_STREAM_FLAG_NONE,
                        &frame.headers.pri_spec, http2_STREAM_INITIAL,
                        aux_data.stream_user_data);
                    
                    if (stream == NULL) {
                        return ErrorCode.NOMEM;
                    }
                    
                    rv = session_predicate_request_headers_send(session, item);
                    if (rv != 0) {
                        return rv;
                    }
                    
                    if (session_enforce_http_messaging(session)) {
                        http2_http_record_request_method(stream, frame);
                    }
                } else {
                    http2_stream *stream;
                    
                    stream = http2_session_get_stream(session, frame.hd.stream_id);
                    
                    if (session_predicate_push_response_headers_send(session, stream) ==
                        0) {
                        frame.headers.cat = http2_HCAT_PUSH_RESPONSE;
                        
                        if (aux_data.stream_user_data) {
                            stream.stream_user_data = aux_data.stream_user_data;
                        }
                    } else if (session_predicate_response_headers_send(session, stream) ==
                        0) {
                        frame.headers.cat = http2_HCAT_RESPONSE;
                    } else {
                        frame.headers.cat = http2_HCAT_HEADERS;
                        
                        rv = session_predicate_headers_send(session, stream);
                        
                        if (rv != 0) {
                            if (stream && stream.item == item) {
                                int rv2;
                                
                                rv2 = http2_stream_detach_item(stream, session);
                                
                                if (http2_is_fatal(rv2)) {
                                    return rv2;
                                }
                            }
                            
                            return rv;
                        }
                    }
                }
                
                rv = http2_frame_pack_headers(&session.aob.framebufs, &frame.headers,
                    &session.hd_deflater);
                
                if (rv != 0) {
                    return rv;
                }
                
                DEBUGF(fprintf(stderr,
                        "send: before padding, HEADERS serialized in %zd bytes\n",
                        http2_bufs_len(&session.aob.framebufs)));
                
                rv = session_headers_add_pad(session, frame);
                
                if (rv != 0) {
                    return rv;
                }
                
                DEBUGF(fprintf(stderr, "send: HEADERS finally serialized in %zd bytes\n",
                        http2_bufs_len(&session.aob.framebufs)));
                
                break;
            }
            case http2_PRIORITY: {
                if (session_is_closing(session)) {
                    return ErrorCode.SESSION_CLOSING;
                }
                /* PRIORITY frame can be sent at any time and to any stream
         ID. */
                http2_frame_pack_priority(&session.aob.framebufs, &frame.priority);
                
                /* Peer can send PRIORITY frame against idle stream to create
         "anchor" in dependency tree.  Only client can do this in
         nghttp2.  In nghttp2, only server retains non-active (closed
         or idle) streams in memory, so we don't open stream here. */
                break;
            }
            case http2_RST_STREAM:
                if (session_is_closing(session)) {
                    return ErrorCode.SESSION_CLOSING;
                }
                http2_frame_pack_rst_stream(&session.aob.framebufs,
                    &frame.rst_stream);
                break;
            case http2_SETTINGS: {
                rv = http2_frame_pack_settings(&session.aob.framebufs,
                    &frame.settings);
                if (rv != 0) {
                    return rv;
                }
                break;
            }
            case http2_PUSH_PROMISE: {
                http2_stream *stream;
                http2_headers_aux_data *aux_data;
                http2_priority_spec pri_spec;
                size_t estimated_payloadlen;
                
                aux_data = &item.aux_data.headers;
                
                stream = http2_session_get_stream(session, frame.hd.stream_id);
                
                /* stream could be NULL if associated stream was already
         closed. */
                if (stream) {
                    http2_priority_spec_init(&pri_spec, stream.stream_id,
                        http2_DEFAULT_WEIGHT, 0);
                } else {
                    http2_priority_spec_default_init(&pri_spec);
                }
                
                if (!http2_session_open_stream(
                        session, frame.push_promise.promised_stream_id,
                        http2_STREAM_FLAG_NONE, &pri_spec, http2_STREAM_RESERVED,
                        aux_data.stream_user_data)) {
                    return ErrorCode.NOMEM;
                }
                
                estimated_payloadlen = session_estimate_headers_payload(
                    session, frame.push_promise.nva, frame.push_promise.nvlen, 0);
                
                if (estimated_payloadlen > http2_MAX_HEADERSLEN) {
                    return ErrorCode.FRAME_SIZE_ERROR;
                }
                
                /* predicte should fail if stream is NULL. */
                rv = session_predicate_push_promise_send(session, stream);
                if (rv != 0) {
                    return rv;
                }
                
                assert(stream);
                
                rv = http2_frame_pack_push_promise(
                    &session.aob.framebufs, &frame.push_promise, &session.hd_deflater);
                if (rv != 0) {
                    return rv;
                }
                rv = session_headers_add_pad(session, frame);
                if (rv != 0) {
                    return rv;
                }
                
                break;
            }
            case http2_PING:
                if (session_is_closing(session)) {
                    return ErrorCode.SESSION_CLOSING;
                }
                http2_frame_pack_ping(&session.aob.framebufs, &frame.ping);
                break;
            case http2_WINDOW_UPDATE: {
                rv = session_predicate_window_update_send(session, frame.hd.stream_id);
                if (rv != 0) {
                    return rv;
                }
                http2_frame_pack_window_update(&session.aob.framebufs,
                    &frame.window_update);
                break;
            }
            case http2_GOAWAY:
                rv = http2_frame_pack_goaway(&session.aob.framebufs, &frame.goaway);
                if (rv != 0) {
                    return rv;
                }
                session.local_last_stream_id = frame.goaway.last_stream_id;
                
                break;
            default:
                return ErrorCode.INVALID_ARGUMENT;
        }
        return 0;
    } else {
        size_t next_readmax;
        http2_stream *stream;
        
        stream = http2_session_get_stream(session, frame.hd.stream_id);
        
        if (stream) {
            assert(stream.item == item);
        }
        
        rv = http2_session_predicate_data_send(session, stream);
        if (rv != 0) {
            if (stream) {
                int rv2;
                
                rv2 = http2_stream_detach_item(stream, session);
                
                if (http2_is_fatal(rv2)) {
                    return rv2;
                }
            }
            
            return rv;
        }
        /* Assuming stream is not NULL */
        assert(stream);
        next_readmax = http2_session_next_data_read(session, stream);
        
        if (next_readmax == 0) {
            
            /* This must be true since we only pop DATA frame item from
         queue when session.remote_window_size > 0 */
            assert(session.remote_window_size > 0);
            
            rv = http2_stream_defer_item(
                stream, http2_STREAM_FLAG_DEFERRED_FLOW_CONTROL, session);
            
            if (http2_is_fatal(rv)) {
                return rv;
            }
            
            session.aob.item = NULL;
            active_outbound_item_reset(&session.aob, mem);
            return ErrorCode.DEFERRED;
        }
        
        rv = http2_session_pack_data(session, &session.aob.framebufs,
            next_readmax, frame, &item.aux_data.data);
        if (rv == ErrorCode.DEFERRED) {
            rv = http2_stream_defer_item(stream, http2_STREAM_FLAG_DEFERRED_USER,
                session);
            
            if (http2_is_fatal(rv)) {
                return rv;
            }
            
            session.aob.item = NULL;
            active_outbound_item_reset(&session.aob, mem);
            return ErrorCode.DEFERRED;
        }
        if (rv == ErrorCode.TEMPORAL_CALLBACK_FAILURE) {
            rv = http2_stream_detach_item(stream, session);
            
            if (http2_is_fatal(rv)) {
                return rv;
            }
            
            rv = http2_session_add_rst_stream(session, frame.hd.stream_id,
                http2_INTERNAL_ERROR);
            if (http2_is_fatal(rv)) {
                return rv;
            }
            return ErrorCode.TEMPORAL_CALLBACK_FAILURE;
        }
        if (rv != 0) {
            int rv2;
            
            rv2 = http2_stream_detach_item(stream, session);
            
            if (http2_is_fatal(rv2)) {
                return rv2;
            }
            
            return rv;
        }
        return 0;
    }
}

/* Used only for tests */
http2_outbound_item *http2_session_get_ob_pq_top(http2_session *session) {
    return (http2_outbound_item *)http2_pq_top(&session.ob_pq);
}

http2_outbound_item *
http2_session_get_next_ob_item(http2_session *session) {
    http2_outbound_item *item, *headers_item;
    
    if (http2_pq_empty(&session.ob_pq)) {
        if (http2_pq_empty(&session.ob_ss_pq)) {
            if (session.remote_window_size == 0 ||
                http2_pq_empty(&session.ob_da_pq)) {
                return NULL;
            }
            
            return http2_pq_top(&session.ob_da_pq);
        }
        
        /* Return item only when concurrent connection limit is not
       reached */
        if (session_is_outgoing_concurrent_streams_max(session)) {
            if (session.remote_window_size == 0 ||
                http2_pq_empty(&session.ob_da_pq)) {
                return NULL;
            }
            
            return http2_pq_top(&session.ob_da_pq);
        }
        
        return http2_pq_top(&session.ob_ss_pq);
    }
    
    if (http2_pq_empty(&session.ob_ss_pq)) {
        return http2_pq_top(&session.ob_pq);
    }
    
    item = http2_pq_top(&session.ob_pq);
    headers_item = http2_pq_top(&session.ob_ss_pq);
    
    if (session_is_outgoing_concurrent_streams_max(session) ||
        item.weight > headers_item.weight ||
        (item.weight == headers_item.weight && item.seq < headers_item.seq)) {
        return item;
    }
    
    return headers_item;
}

http2_outbound_item *
http2_session_pop_next_ob_item(http2_session *session) {
    http2_outbound_item *item, *headers_item;
    
    if (http2_pq_empty(&session.ob_pq)) {
        if (http2_pq_empty(&session.ob_ss_pq)) {
            if (session.remote_window_size == 0 ||
                http2_pq_empty(&session.ob_da_pq)) {
                return NULL;
            }
            
            item = http2_pq_top(&session.ob_da_pq);
            http2_pq_pop(&session.ob_da_pq);
            
            item.queued = 0;
            
            return item;
        }
        
        /* Pop item only when concurrent connection limit is not
       reached */
        if (session_is_outgoing_concurrent_streams_max(session)) {
            if (session.remote_window_size == 0 ||
                http2_pq_empty(&session.ob_da_pq)) {
                return NULL;
            }
            
            item = http2_pq_top(&session.ob_da_pq);
            http2_pq_pop(&session.ob_da_pq);
            
            item.queued = 0;
            
            return item;
        }
        
        item = http2_pq_top(&session.ob_ss_pq);
        http2_pq_pop(&session.ob_ss_pq);
        
        item.queued = 0;
        
        return item;
    }
    
    if (http2_pq_empty(&session.ob_ss_pq)) {
        item = http2_pq_top(&session.ob_pq);
        http2_pq_pop(&session.ob_pq);
        
        item.queued = 0;
        
        return item;
    }
    
    item = http2_pq_top(&session.ob_pq);
    headers_item = http2_pq_top(&session.ob_ss_pq);
    
    if (session_is_outgoing_concurrent_streams_max(session) ||
        item.weight > headers_item.weight ||
        (item.weight == headers_item.weight && item.seq < headers_item.seq)) {
        http2_pq_pop(&session.ob_pq);
        
        item.queued = 0;
        
        return item;
    }
    
    http2_pq_pop(&session.ob_ss_pq);
    
    headers_item.queued = 0;
    
    return headers_item;
}

static int session_call_before_frame_send(http2_session *session,
    http2_frame *frame) {
    int rv;
    if (session.callbacks.before_frame_send_callback) {
        rv = session.callbacks.before_frame_send_callback(session, frame,
            session.user_data);
        if (rv != 0) {
            return ErrorCode.CALLBACK_FAILURE;
        }
    }
    return 0;
}

static int session_call_on_frame_send(http2_session *session,
    http2_frame *frame) {
    int rv;
    if (session.callbacks.on_frame_send_callback) {
        rv = session.callbacks.on_frame_send_callback(session, frame,
            session.user_data);
        if (rv != 0) {
            return ErrorCode.CALLBACK_FAILURE;
        }
    }
    return 0;
}

static int find_stream_on_goaway_func(http2_map_entry *entry, void *ptr) {
    http2_close_stream_on_goaway_arg *arg;
    http2_stream *stream;
    
    arg = (http2_close_stream_on_goaway_arg *)ptr;
    stream = (http2_stream *)entry;
    
    if (http2_session_is_my_stream_id(arg.session, stream.stream_id)) {
        if (arg.incoming) {
            return 0;
        }
    } else if (!arg.incoming) {
        return 0;
    }
    
    if (stream.state != http2_STREAM_IDLE &&
        (stream.flags & http2_STREAM_FLAG_CLOSED) == 0 &&
        stream.stream_id > arg.last_stream_id) {
        /* We are collecting streams to close because we cannot call
       http2_session_close_stream() inside http2_map_each().
       Reuse closed_next member.. bad choice? */
        assert(stream.closed_next == NULL);
        assert(stream.closed_prev == NULL);
        
        if (arg.head) {
            stream.closed_next = arg.head;
            arg.head = stream;
        } else {
            arg.head = stream;
        }
    }
    
    return 0;
}

/* Closes non-idle and non-closed streams whose stream ID >
   last_stream_id.  If incoming is nonzero, we are going to close
   incoming streams.  Otherwise, close outgoing streams. */
static int session_close_stream_on_goaway(http2_session *session,
    int last_stream_id,
    int incoming) {
    int rv;
    http2_stream *stream, *next_stream;
    http2_close_stream_on_goaway_arg arg = {session, NULL, last_stream_id,
        incoming};
    
    rv = http2_map_each(&session.streams, find_stream_on_goaway_func, &arg);
    assert(rv == 0);
    
    stream = arg.head;
    while (stream) {
        next_stream = stream.closed_next;
        stream.closed_next = NULL;
        rv = http2_session_close_stream(session, stream.stream_id,
            http2_REFUSED_STREAM);
        
        /* stream may be deleted here */
        
        stream = next_stream;
        
        if (http2_is_fatal(rv)) {
            /* Clean up closed_next member just in case */
            while (stream) {
                next_stream = stream.closed_next;
                stream.closed_next = NULL;
                stream = next_stream;
            }
            return rv;
        }
    }
    
    return 0;
}

static void session_outbound_item_cycle_weight(http2_session *session,
    http2_outbound_item *item,
    int ini_weight) {
    if (item.weight == http2_MIN_WEIGHT || item.weight > ini_weight) {
        
        item.weight = ini_weight;
        
        if (item.cycle == session.last_cycle) {
            item.cycle = ++session.last_cycle;
        } else {
            item.cycle = session.last_cycle;
        }
    } else {
        --item.weight;
    }
}

/*
 * Called after a frame is sent.  This function runs
 * on_frame_send_callback and handles stream closure upon END_STREAM
 * or RST_STREAM.  This function does not reset session.aob.  It is a
 * responsibility of session_after_frame_sent2.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.NOMEM
 *     Out of memory.
 * ErrorCode.CALLBACK_FAILURE
 *     The callback function failed.
 */
static int session_after_frame_sent1(http2_session *session) {
    int rv;
    http2_active_outbound_item *aob = &session.aob;
    http2_outbound_item *item = aob.item;
    http2_bufs *framebufs = &aob.framebufs;
    http2_frame *frame;
    
    frame = &item.frame;
    
    if (frame.hd.type != http2_DATA) {
        
        if (frame.hd.type == http2_HEADERS ||
            frame.hd.type == http2_PUSH_PROMISE) {
            
            if (http2_bufs_next_present(framebufs)) {
                DEBUGF(fprintf(stderr, "send: CONTINUATION exists, just return\n"));
                return 0;
            }
        }
        rv = session_call_on_frame_send(session, frame);
        if (http2_is_fatal(rv)) {
            return rv;
        }
        switch (frame.hd.type) {
            case http2_HEADERS: {
                http2_headers_aux_data *aux_data;
                http2_stream *stream;
                
                stream = http2_session_get_stream(session, frame.hd.stream_id);
                if (!stream) {
                    break;
                }
                
                if (stream.item == item) {
                    rv = http2_stream_detach_item(stream, session);
                    
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                }
                
                switch (frame.headers.cat) {
                    case http2_HCAT_REQUEST: {
                        stream.state = http2_STREAM_OPENING;
                        if (frame.hd.flags & http2_FLAG_END_STREAM) {
                            http2_stream_shutdown(stream, http2_SHUT_WR);
                        }
                        rv = http2_session_close_stream_if_shut_rdwr(session, stream);
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                        /* We assume aux_data is a pointer to http2_headers_aux_data */
                        aux_data = &item.aux_data.headers;
                        if (aux_data.data_prd.read_callback) {
                            /* http2_submit_data() makes a copy of aux_data.data_prd */
                            rv = http2_submit_data(session, http2_FLAG_END_STREAM,
                                frame.hd.stream_id, &aux_data.data_prd);
                            if (http2_is_fatal(rv)) {
                                return rv;
                            }
                            /* TODO http2_submit_data() may fail if stream has already
             DATA frame item.  We might have to handle it here. */
                        }
                        break;
                    }
                    case http2_HCAT_PUSH_RESPONSE:
                        stream.flags &= ~http2_STREAM_FLAG_PUSH;
                        ++session.num_outgoing_streams;
                        /* Fall through */
                    case http2_HCAT_RESPONSE:
                        stream.state = http2_STREAM_OPENED;
                        /* Fall through */
                    case http2_HCAT_HEADERS:
                        if (frame.hd.flags & http2_FLAG_END_STREAM) {
                            http2_stream_shutdown(stream, http2_SHUT_WR);
                        }
                        rv = http2_session_close_stream_if_shut_rdwr(session, stream);
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                        /* We assume aux_data is a pointer to http2_headers_aux_data */
                        aux_data = &item.aux_data.headers;
                        if (aux_data.data_prd.read_callback) {
                            rv = http2_submit_data(session, http2_FLAG_END_STREAM,
                                frame.hd.stream_id, &aux_data.data_prd);
                            if (http2_is_fatal(rv)) {
                                return rv;
                            }
                            /* TODO http2_submit_data() may fail if stream has already
             DATA frame item.  We might have to handle it here. */
                        }
                        break;
                }
                break;
            }
            case http2_PRIORITY: {
                http2_stream *stream;
                
                if (session.server) {
                    break;
                }
                
                stream = http2_session_get_stream_raw(session, frame.hd.stream_id);
                
                if (!stream) {
                    break;
                }
                
                rv = http2_session_reprioritize_stream(session, stream,
                    &frame.priority.pri_spec);
                
                if (http2_is_fatal(rv)) {
                    return rv;
                }
                
                break;
            }
            case http2_RST_STREAM:
                rv = http2_session_close_stream(session, frame.hd.stream_id,
                    frame.rst_stream.error_code);
                if (http2_is_fatal(rv)) {
                    return rv;
                }
                break;
            case http2_GOAWAY: {
                http2_goaway_aux_data *aux_data;
                
                aux_data = &item.aux_data.goaway;
                
                if ((aux_data.flags & http2_GOAWAY_AUX_SHUTDOWN_NOTICE) == 0) {
                    
                    if (aux_data.flags & http2_GOAWAY_AUX_TERM_ON_SEND) {
                        session.goaway_flags |= http2_GOAWAY_TERM_SENT;
                    }
                    
                    session.goaway_flags |= http2_GOAWAY_SENT;
                    
                    rv = session_close_stream_on_goaway(session,
                        frame.goaway.last_stream_id, 1);
                    
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                }
                
                break;
            }
            default:
                break;
        }
        
        return 0;
    } else {
        http2_stream *stream;
        http2_data_aux_data *aux_data;
        
        aux_data = &item.aux_data.data;
        
        stream = http2_session_get_stream(session, frame.hd.stream_id);
        /* We update flow control window after a frame was completely
       sent. This is possible because we choose payload length not to
       exceed the window */
        session.remote_window_size -= frame.hd.length;
        if (stream) {
            stream.remote_window_size -= frame.hd.length;
        }
        
        if (stream && aux_data.eof) {
            rv = http2_stream_detach_item(stream, session);
            
            if (http2_is_fatal(rv)) {
                return rv;
            }
            
            /* Call on_frame_send_callback after
         http2_stream_detach_item(), so that application can issue
         http2_submit_data() in the callback. */
            if (session.callbacks.on_frame_send_callback) {
                rv = session_call_on_frame_send(session, frame);
                
                if (http2_is_fatal(rv)) {
                    return rv;
                }
            }
            
            if (frame.hd.flags & http2_FLAG_END_STREAM) {
                int stream_closed;
                
                stream_closed =
                    (stream.shut_flags & http2_SHUT_RDWR) == http2_SHUT_RDWR;
                
                http2_stream_shutdown(stream, http2_SHUT_WR);
                
                rv = http2_session_close_stream_if_shut_rdwr(session, stream);
                if (http2_is_fatal(rv)) {
                    return rv;
                }
                /* stream may be NULL if it was closed */
                if (stream_closed) {
                    stream = NULL;
                }
            }
            return 0;
        }
        
        if (session.callbacks.on_frame_send_callback) {
            rv = session_call_on_frame_send(session, frame);
            
            if (http2_is_fatal(rv)) {
                return rv;
            }
        }
        
        return 0;
    }
    /* Unreachable */
    assert(0);
    return 0;
}

/*
 * Called after a frame is sent and session_after_frame_sent1.  This
 * function is responsible to reset session.aob.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.NOMEM
 *     Out of memory.
 * ErrorCode.CALLBACK_FAILURE
 *     The callback function failed.
 */
static int session_after_frame_sent2(http2_session *session) {
    int rv;
    http2_active_outbound_item *aob = &session.aob;
    http2_outbound_item *item = aob.item;
    http2_bufs *framebufs = &aob.framebufs;
    http2_frame *frame;
    http2_mem *mem;
    
    mem = &session.mem;
    frame = &item.frame;
    
    if (frame.hd.type != http2_DATA) {
        
        if (frame.hd.type == http2_HEADERS ||
            frame.hd.type == http2_PUSH_PROMISE) {
            
            if (http2_bufs_next_present(framebufs)) {
                framebufs.cur = framebufs.cur.next;
                
                DEBUGF(fprintf(stderr, "send: next CONTINUATION frame, %zu bytes\n",
                        http2_buf_len(&framebufs.cur.buf)));
                
                return 0;
            }
        }
        
        active_outbound_item_reset(&session.aob, mem);
        
        return 0;
    } else {
        http2_outbound_item *next_item;
        http2_stream *stream;
        http2_data_aux_data *aux_data;
        
        aux_data = &item.aux_data.data;
        
        /* On EOF, we have already detached data.  Please note that
       application may issue http2_submit_data() in
       on_frame_send_callback (call from session_after_frame_sent1),
       which attach data to stream.  We don't want to detach it. */
        if (aux_data.eof) {
            active_outbound_item_reset(aob, mem);
            
            return 0;
        }
        
        stream = http2_session_get_stream(session, frame.hd.stream_id);
        
        /* If session is closed or RST_STREAM was queued, we won't send
       further data. */
        if (http2_session_predicate_data_send(session, stream) != 0) {
            if (stream) {
                rv = http2_stream_detach_item(stream, session);
                
                if (http2_is_fatal(rv)) {
                    return rv;
                }
            }
            
            active_outbound_item_reset(aob, mem);
            
            return 0;
        }
        
        /* Assuming stream is not NULL */
        assert(stream);
        next_item = http2_session_get_next_ob_item(session);
        
        /* Imagine we hit connection window size limit while sending DATA
       frame.  If we decrement weight here, its stream might get
       inferior share because the other streams' weight is not
       decremented because of flow control. */
        if (session.remote_window_size > 0 || stream.remote_window_size <= 0) {
            session_outbound_item_cycle_weight(session, aob.item,
                stream.effective_weight);
        }
        
        /* If priority of this stream is higher or equal to other stream
       waiting at the top of the queue, we continue to send this
       data. */
        if (stream.dpri == http2_STREAM_DPRI_TOP &&
            (next_item == NULL || outbound_item_compar(item, next_item) < 0)) {
            size_t next_readmax;
            
            next_readmax = http2_session_next_data_read(session, stream);
            
            if (next_readmax == 0) {
                
                if (session.remote_window_size == 0 &&
                    stream.remote_window_size > 0) {
                    
                    /* If DATA cannot be sent solely due to connection level
             window size, just push item to queue again.  We never pop
             DATA item while connection level window size is 0. */
                    rv = http2_pq_push(&session.ob_da_pq, aob.item);
                    
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                    
                    aob.item.queued = 1;
                } else {
                    rv = http2_stream_defer_item(
                        stream, http2_STREAM_FLAG_DEFERRED_FLOW_CONTROL, session);
                    
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                }
                
                aob.item = NULL;
                active_outbound_item_reset(aob, mem);
                
                return 0;
            }
            
            http2_bufs_reset(framebufs);
            
            rv = http2_session_pack_data(session, framebufs, next_readmax, frame,
                aux_data);
            if (http2_is_fatal(rv)) {
                return rv;
            }
            if (rv == ErrorCode.DEFERRED) {
                rv = http2_stream_defer_item(
                    stream, http2_STREAM_FLAG_DEFERRED_USER, session);
                
                if (http2_is_fatal(rv)) {
                    return rv;
                }
                
                aob.item = NULL;
                active_outbound_item_reset(aob, mem);
                
                return 0;
            }
            if (rv == ErrorCode.TEMPORAL_CALLBACK_FAILURE) {
                /* Stop DATA frame chain and issue RST_STREAM to close the
           stream.  We don't return
           ErrorCode.TEMPORAL_CALLBACK_FAILURE intentionally. */
                rv = http2_session_add_rst_stream(session, frame.hd.stream_id,
                    http2_INTERNAL_ERROR);
                
                if (http2_is_fatal(rv)) {
                    return rv;
                }
                
                rv = http2_stream_detach_item(stream, session);
                
                if (http2_is_fatal(rv)) {
                    return rv;
                }
                
                active_outbound_item_reset(aob, mem);
                
                return 0;
            }
            assert(rv == 0);
            
            return 0;
        }
        
        if (stream.dpri == http2_STREAM_DPRI_TOP) {
            rv = http2_pq_push(&session.ob_da_pq, aob.item);
            
            if (http2_is_fatal(rv)) {
                return rv;
            }
            
            aob.item.queued = 1;
        }
        
        aob.item = NULL;
        active_outbound_item_reset(&session.aob, mem);
        return 0;
    }
    /* Unreachable */
    assert(0);
    return 0;
}

static size_t http2_session_mem_send_internal(http2_session *session,
    const ubyte **data_ptr, int fast_cb) {
    int rv;
    http2_active_outbound_item *aob;
    http2_bufs *framebufs;
    http2_mem *mem;
    
    mem = &session.mem;
    aob = &session.aob;
    framebufs = &aob.framebufs;
    
    *data_ptr = NULL;
    for (;;) {
        switch (aob.state) {
            case http2_OB_POP_ITEM: {
                http2_outbound_item *item;
                
                item = http2_session_pop_next_ob_item(session);
                if (item == NULL) {
                    return 0;
                }
                
                if (item.frame.hd.type == http2_DATA ||
                    item.frame.hd.type == http2_HEADERS) {
                    http2_frame *frame;
                    http2_stream *stream;
                    
                    frame = &item.frame;
                    stream = http2_session_get_stream(session, frame.hd.stream_id);
                    
                    if (stream && item == stream.item &&
                        stream.dpri != http2_STREAM_DPRI_TOP) {
                        /* We have DATA with higher priority in queue within the
             same dependency tree. */
                        break;
                    }
                }
                
                rv = session_prep_frame(session, item);
                if (rv == ErrorCode.DEFERRED) {
                    DEBUGF(fprintf(stderr, "send: frame transmission deferred\n"));
                    break;
                }
                if (rv < 0) {
                    int opened_stream_id = 0;
                    uint error_code = http2_INTERNAL_ERROR;
                    
                    DEBUGF(fprintf(stderr, "send: frame preparation failed with %s\n",
                            http2_strerror(rv)));
                    /* TODO If the error comes from compressor, the connection
           must be closed. */
                    if (item.frame.hd.type != http2_DATA &&
                        session.callbacks.on_frame_not_send_callback && is_non_fatal(rv)) {
                        http2_frame *frame = &item.frame;
                        /* The library is responsible for the transmission of
             WINDOW_UPDATE frame, so we don't call error callback for
             it. */
                        if (frame.hd.type != http2_WINDOW_UPDATE &&
                            session.callbacks.on_frame_not_send_callback(
                                session, frame, rv, session.user_data) != 0) {
                            
                            http2_outbound_item_free(item, mem);
                            http2_mem_free(mem, item);
                            
                            return ErrorCode.CALLBACK_FAILURE;
                        }
                    }
                    /* We have to close stream opened by failed request HEADERS
           or PUSH_PROMISE. */
                    switch (item.frame.hd.type) {
                        case http2_HEADERS:
                            if (item.frame.headers.cat == http2_HCAT_REQUEST) {
                                opened_stream_id = item.frame.hd.stream_id;
                                if (item.aux_data.headers.canceled) {
                                    error_code = item.aux_data.headers.error_code;
                                }
                            }
                            break;
                        case http2_PUSH_PROMISE:
                            opened_stream_id = item.frame.push_promise.promised_stream_id;
                            break;
                    }
                    if (opened_stream_id) {
                        /* careful not to override rv */
                        int rv2;
                        rv2 = http2_session_close_stream(session, opened_stream_id,
                            error_code);
                        
                        if (http2_is_fatal(rv2)) {
                            return rv2;
                        }
                    }
                    
                    http2_outbound_item_free(item, mem);
                    http2_mem_free(mem, item);
                    active_outbound_item_reset(aob, mem);
                    
                    if (rv == ErrorCode.HEADER_COMP) {
                        /* If header compression error occurred, should terminiate
             connection. */
                        rv = http2_session_terminate_session(session,
                            http2_INTERNAL_ERROR);
                    }
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                    break;
                }
                
                aob.item = item;
                
                http2_bufs_rewind(framebufs);
                
                if (item.frame.hd.type != http2_DATA) {
                    http2_frame *frame;
                    
                    frame = &item.frame;
                    
                    DEBUGF(fprintf(stderr, "send: next frame: payloadlen=%zu, type=%u, "
                            "flags=0x%02x, stream_id=%d\n",
                            frame.hd.length, frame.hd.type, frame.hd.flags,
                            frame.hd.stream_id));
                    
                    rv = session_call_before_frame_send(session, frame);
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                } else {
                    DEBUGF(fprintf(stderr, "send: next frame: DATA\n"));
                }
                
                DEBUGF(fprintf(stderr,
                        "send: start transmitting frame type=%u, length=%zd\n",
                        framebufs.cur.buf.pos[3],
                        framebufs.cur.buf.last - framebufs.cur.buf.pos));
                
                aob.state = http2_OB_SEND_DATA;
                
                break;
            }
            case http2_OB_SEND_DATA: {
                size_t datalen;
                http2_buf *buf;
                
                buf = &framebufs.cur.buf;
                
                if (buf.pos == buf.last) {
                    DEBUGF(fprintf(stderr, "send: end transmission of a frame\n"));
                    
                    /* Frame has completely sent */
                    if (fast_cb) {
                        rv = session_after_frame_sent2(session);
                    } else {
                        rv = session_after_frame_sent1(session);
                        if (rv < 0) {
                            /* FATAL */
                            assert(http2_is_fatal(rv));
                            return rv;
                        }
                        rv = session_after_frame_sent2(session);
                    }
                    if (rv < 0) {
                        /* FATAL */
                        assert(http2_is_fatal(rv));
                        return rv;
                    }
                    /* We have already adjusted the next state */
                    break;
                }
                
                *data_ptr = buf.pos;
                datalen = http2_buf_len(buf);
                
                /* We increment the offset here. If send_callback does not send
         everything, we will adjust it. */
                buf.pos += datalen;
                
                return datalen;
            }
        }
    }
}

size_t http2_session_mem_send(http2_session *session,
    const ubyte **data_ptr) {
    int rv;
    size_t len;
    
    len = http2_session_mem_send_internal(session, data_ptr, 1);
    if (len <= 0) {
        return len;
    }
    
    /* We have to call session_after_frame_sent1 here to handle stream
     closure upon transmission of frames.  Otherwise, END_STREAM may
     be reached to client before we call http2_session_mem_send
     again and we may get exceeding number of incoming streams. */
    rv = session_after_frame_sent1(session);
    if (rv < 0) {
        assert(http2_is_fatal(rv));
        return (size_t)rv;
    }
    
    return len;
}

int http2_session_send(http2_session *session) {
    const ubyte *data;
    size_t datalen;
    size_t sentlen;
    http2_bufs *framebufs;
    
    framebufs = &session.aob.framebufs;
    
    for (;;) {
        datalen = http2_session_mem_send_internal(session, &data, 0);
        if (datalen <= 0) {
            return (int)datalen;
        }
        sentlen = session.callbacks.send_callback(session, data, datalen, 0,
            session.user_data);
        if (sentlen < 0) {
            if (sentlen == ErrorCode.WOULDBLOCK) {
                /* Transmission canceled. Rewind the offset */
                framebufs.cur.buf.pos -= datalen;
                
                return 0;
            }
            return ErrorCode.CALLBACK_FAILURE;
        }
        /* Rewind the offset to the amount of unsent bytes */
        framebufs.cur.buf.pos -= datalen - sentlen;
    }
}

static size_t session_recv(http2_session *session, ubyte *buf,
    size_t len) {
    size_t rv;
    rv = session.callbacks.recv_callback(session, buf, len, 0,
        session.user_data);
    if (rv > 0) {
        if ((size_t)rv > len) {
            return ErrorCode.CALLBACK_FAILURE;
        }
    } else if (rv < 0 && rv != ErrorCode.WOULDBLOCK && rv != ErrorCode.EOF) {
        return ErrorCode.CALLBACK_FAILURE;
    }
    return rv;
}

static int session_call_on_begin_frame(http2_session *session,
    const http2_frame_hd *hd) {
    int rv;
    
    if (session.callbacks.on_begin_frame_callback) {
        
        rv = session.callbacks.on_begin_frame_callback(session, hd,
            session.user_data);
        
        if (rv != 0) {
            return ErrorCode.CALLBACK_FAILURE;
        }
    }
    
    return 0;
}

static int session_call_on_frame_received(http2_session *session,
    http2_frame *frame) {
    int rv;
    if (session.callbacks.on_frame_recv_callback) {
        rv = session.callbacks.on_frame_recv_callback(session, frame,
            session.user_data);
        if (rv != 0) {
            return ErrorCode.CALLBACK_FAILURE;
        }
    }
    return 0;
}

static int session_call_on_begin_headers(http2_session *session,
    http2_frame *frame) {
    int rv;
    DEBUGF(fprintf(stderr, "recv: call on_begin_headers callback stream_id=%d\n",
            frame.hd.stream_id));
    if (session.callbacks.on_begin_headers_callback) {
        rv = session.callbacks.on_begin_headers_callback(session, frame,
            session.user_data);
        if (rv != 0) {
            return ErrorCode.CALLBACK_FAILURE;
        }
    }
    return 0;
}

static int session_call_on_header(http2_session *session,
    const http2_frame *frame,
    const http2_nv *nv) {
    int rv;
    if (session.callbacks.on_header_callback) {
        rv = session.callbacks.on_header_callback(
            session, frame, nv.name, nv.namelen, nv.value, nv.valuelen,
            nv.flags, session.user_data);
        if (rv == ErrorCode.PAUSE ||
            rv == ErrorCode.TEMPORAL_CALLBACK_FAILURE) {
            return rv;
        }
        if (rv != 0) {
            return ErrorCode.CALLBACK_FAILURE;
        }
    }
    return 0;
}

/*
 * Handles frame size error.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.NOMEM
 *   Out of memory.
 */
static int session_handle_frame_size_error(http2_session *session,
    http2_frame *frame _U_) {
    /* TODO Currently no callback is called for this error, because we
     call this callback before reading any payload */
    return http2_session_terminate_session(session, http2_FRAME_SIZE_ERROR);
}

static int session_handle_invalid_stream(http2_session *session,
    http2_frame *frame,
    uint error_code) {
    int rv;
    rv = http2_session_add_rst_stream(session, frame.hd.stream_id, error_code);
    if (rv != 0) {
        return rv;
    }
    if (session.callbacks.on_invalid_frame_recv_callback) {
        if (session.callbacks.on_invalid_frame_recv_callback(
                session, frame, error_code, session.user_data) != 0) {
            return ErrorCode.CALLBACK_FAILURE;
        }
    }
    return 0;
}

static int session_inflate_handle_invalid_stream(http2_session *session,
    http2_frame *frame,
    uint error_code) {
    int rv;
    rv = session_handle_invalid_stream(session, frame, error_code);
    if (http2_is_fatal(rv)) {
        return rv;
    }
    return ErrorCode.IGN_HEADER_BLOCK;
}

/*
 * Handles invalid frame which causes connection error.
 */
static int session_handle_invalid_connection(http2_session *session,
    http2_frame *frame,
    uint error_code,
    const char *reason) {
    if (session.callbacks.on_invalid_frame_recv_callback) {
        if (session.callbacks.on_invalid_frame_recv_callback(
                session, frame, error_code, session.user_data) != 0) {
            return ErrorCode.CALLBACK_FAILURE;
        }
    }
    return http2_session_terminate_session_with_reason(session, error_code,
        reason);
}

static int session_inflate_handle_invalid_connection(http2_session *session,
    http2_frame *frame,
    uint error_code,
    const char *reason) {
    int rv;
    rv = session_handle_invalid_connection(session, frame, error_code, reason);
    if (http2_is_fatal(rv)) {
        return rv;
    }
    return ErrorCode.IGN_HEADER_BLOCK;
}

/*
 * Inflates header block in the memory pointed by |in| with |inlen|
 * bytes. If this function returns ErrorCode.PAUSE, the caller must
 * call this function again, until it returns 0 or one of negative
 * error code.  If |call_header_cb| is zero, the on_header_callback
 * are not invoked and the function never return ErrorCode.PAUSE. If
 * the given |in| is the last chunk of header block, the |final| must
 * be nonzero. If header block is successfully processed (which is
 * indicated by the return value 0, ErrorCode.PAUSE or
 * ErrorCode.TEMPORAL_CALLBACK_FAILURE), the number of processed
 * input bytes is assigned to the |*readlen_ptr|.
 *
 * This function return 0 if it succeeds, or one of the negative error
 * codes:
 *
 * ErrorCode.CALLBACK_FAILURE
 *     The callback function failed.
 * ErrorCode.TEMPORAL_CALLBACK_FAILURE
 *     The callback returns this error code, indicating that this
 *     stream should be RST_STREAMed.
 * ErrorCode.NOMEM
 *     Out of memory.
 * ErrorCode.PAUSE
 *     The callback function returned ErrorCode.PAUSE
 * ErrorCode.HEADER_COMP
 *     Header decompression failed
 */
static int inflate_header_block(http2_session *session, http2_frame *frame,
    size_t *readlen_ptr, ubyte *input, size_t inlen,
    int final_, int call_header_cb) {
    size_t proclen;
    int rv;
    int inflate_flags;
    http2_nv nv;
    http2_stream *stream;
    http2_stream *subject_stream;
    int trailer = 0;
    
    *readlen_ptr = 0;
    stream = http2_session_get_stream(session, frame.hd.stream_id);
    
    if (frame.hd.type == http2_PUSH_PROMISE) {
        subject_stream = http2_session_get_stream(
            session, frame.push_promise.promised_stream_id);
    } else {
        subject_stream = stream;
        trailer = session_trailer_headers(session, stream, frame);
    }
    
    DEBUGF(fprintf(stderr, "recv: decoding header block %zu bytes\n", inlen));
    for (;;) {
        inflate_flags = 0;
        proclen = http2_hd_inflate_hd(&session.hd_inflater, &nv, &inflate_flags,
            input, inlen, final_);
        if (http2_is_fatal((int)proclen)) {
            return (int)proclen;
        }
        if (proclen < 0) {
            if (session.iframe.state == http2_IB_READ_HEADER_BLOCK) {
                if (stream && stream.state != http2_STREAM_CLOSING) {
                    /* Adding RST_STREAM here is very important. It prevents
                         from invoking subsequent callbacks for the same stream
                         ID. */
                    rv = http2_session_add_rst_stream(session, frame.hd.stream_id,
                        http2_COMPRESSION_ERROR);
                    
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                }
            }
            rv =
                http2_session_terminate_session(session, http2_COMPRESSION_ERROR);
            if (http2_is_fatal(rv)) {
                return rv;
            }
            
            return ErrorCode.HEADER_COMP;
        }
        input += proclen;
        inlen -= proclen;
        *readlen_ptr += proclen;
        
        DEBUGF(fprintf(stderr, "recv: proclen=%zd\n", proclen));
        
        if (call_header_cb && (inflate_flags & http2_HD_INFLATE_EMIT)) {
            if (subject_stream && session_enforce_http_messaging(session)) {
                rv = http2_http_on_header(session, subject_stream, frame, &nv,
                    trailer);
                if (rv != 0) {
                    DEBUGF(fprintf(
                            stderr, "recv: HTTP error: type=%d, id=%d, header %.*s: %.*s\n",
                            frame.hd.type, subject_stream.stream_id, (int)nv.namelen,
                            nv.name, (int)nv.valuelen, nv.value));
                    rv = http2_session_add_rst_stream(
                        session, subject_stream.stream_id, http2_PROTOCOL_ERROR);
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                    return ErrorCode.TEMPORAL_CALLBACK_FAILURE;
                }
            }
            if (call_header_cb) {
                rv = session_call_on_header(session, frame, &nv);
                /* This handles ErrorCode.PAUSE and
                    ErrorCode.TEMPORAL_CALLBACK_FAILURE as well */
                if (rv != 0) {
                    return rv;
                }
            }
        }
        if (inflate_flags & http2_HD_INFLATE_FINAL) {
            http2_hd_inflate_end_headers(&session.hd_inflater);
            break;
        }
        if ((inflate_flags & http2_HD_INFLATE_EMIT) == 0 && inlen == 0) {
            break;
        }
    }
    return 0;
}

/*
 * Decompress header blocks of incoming request HEADERS and also call
 * additional callbacks. This function can be called again if this
 * function returns ErrorCode.PAUSE.
 *
 * This function returns 0 if it succeeds, or one of negative error
 * codes:
 *
 * ErrorCode.CALLBACK_FAILURE
 *     The callback function failed.
 * ErrorCode.NOMEM
 *     Out of memory.
 */
int http2_session_end_request_headers_received(http2_session *session, http2_frame *frame, http2_stream *stream)
{
    if (frame.hd.flags & http2_FLAG_END_STREAM) {
        http2_stream_shutdown(stream, http2_SHUT_RD);
    }
    /* Here we assume that stream is not shutdown in http2_SHUT_WR */
    return 0;
}

/*
 * Decompress header blocks of incoming (push-)response HEADERS and
 * also call additional callbacks. This function can be called again
 * if this function returns ErrorCode.PAUSE.
 *
 * This function returns 0 if it succeeds, or one of negative error
 * codes:
 *
 * ErrorCode.CALLBACK_FAILURE
 *     The callback function failed.
 * ErrorCode.NOMEM
 *     Out of memory.
 */
int http2_session_end_response_headers_received(http2_session *session,
    http2_frame *frame,
    http2_stream *stream) {
    int rv;
    if (frame.hd.flags & http2_FLAG_END_STREAM) {
        /* This is the last frame of this stream, so disallow
       further receptions. */
        http2_stream_shutdown(stream, http2_SHUT_RD);
        rv = http2_session_close_stream_if_shut_rdwr(session, stream);
        if (http2_is_fatal(rv)) {
            return rv;
        }
    }
    return 0;
}

/*
 * Decompress header blocks of incoming HEADERS and also call
 * additional callbacks. This function can be called again if this
 * function returns ErrorCode.PAUSE.
 *
 * This function returns 0 if it succeeds, or one of negative error
 * codes:
 *
 * ErrorCode.CALLBACK_FAILURE
 *     The callback function failed.
 * ErrorCode.NOMEM
 *     Out of memory.
 */
int http2_session_end_headers_received(http2_session *session,
    http2_frame *frame,
    http2_stream *stream) {
    int rv;
    if (frame.hd.flags & http2_FLAG_END_STREAM) {
        if (!http2_session_is_my_stream_id(session, frame.hd.stream_id)) {
        }
        http2_stream_shutdown(stream, http2_SHUT_RD);
        rv = http2_session_close_stream_if_shut_rdwr(session, stream);
        if (http2_is_fatal(rv)) {
            return rv;
        }
    }
    return 0;
}

static int session_after_header_block_received(http2_session *session) {
    int rv = 0;
    int call_cb = 1;
    http2_frame *frame = &session.iframe.frame;
    http2_stream *stream;
    
    /* We don't call on_frame_recv_callback if stream has been closed
     already or being closed. */
    stream = http2_session_get_stream(session, frame.hd.stream_id);
    if (!stream || stream.state == http2_STREAM_CLOSING) {
        return 0;
    }
    
    if (session_enforce_http_messaging(session)) {
        if (frame.hd.type == http2_PUSH_PROMISE) {
            http2_stream *subject_stream;
            
            subject_stream = http2_session_get_stream(
                session, frame.push_promise.promised_stream_id);
            if (subject_stream) {
                rv = http2_http_on_request_headers(subject_stream, frame);
            }
        } else {
            assert(frame.hd.type == http2_HEADERS);
            switch (frame.headers.cat) {
                case http2_HCAT_REQUEST:
                    rv = http2_http_on_request_headers(stream, frame);
                    break;
                case http2_HCAT_RESPONSE:
                case http2_HCAT_PUSH_RESPONSE:
                    rv = http2_http_on_response_headers(stream);
                    break;
                case http2_HCAT_HEADERS:
                    if (stream.http_flags & http2_HTTP_FLAG_EXPECT_FINAL_RESPONSE) {
                        assert(!session.server);
                        rv = http2_http_on_response_headers(stream);
                    } else {
                        rv = http2_http_on_trailer_headers(stream, frame);
                    }
                    break;
                default:
                    assert(0);
            }
            if (rv == 0 && (frame.hd.flags & http2_FLAG_END_STREAM)) {
                rv = http2_http_on_remote_end_stream(stream);
            }
        }
        if (rv != 0) {
            int stream_id;
            
            if (frame.hd.type == http2_PUSH_PROMISE) {
                stream_id = frame.push_promise.promised_stream_id;
            } else {
                stream_id = frame.hd.stream_id;
            }
            
            call_cb = 0;
            
            rv = http2_session_add_rst_stream(session, stream_id,
                http2_PROTOCOL_ERROR);
            if (http2_is_fatal(rv)) {
                return rv;
            }
        }
    }
    
    if (call_cb) {
        rv = session_call_on_frame_received(session, frame);
        if (http2_is_fatal(rv)) {
            return rv;
        }
    }
    
    if (frame.hd.type != http2_HEADERS) {
        return 0;
    }
    
    switch (frame.headers.cat) {
        case http2_HCAT_REQUEST:
            return http2_session_end_request_headers_received(session, frame, stream);
        case http2_HCAT_RESPONSE:
        case http2_HCAT_PUSH_RESPONSE:
            return http2_session_end_response_headers_received(session, frame,
                stream);
        case http2_HCAT_HEADERS:
            return http2_session_end_headers_received(session, frame, stream);
        default:
            assert(0);
    }
    return 0;
}

int http2_session_on_request_headers_received(http2_session *session,
    http2_frame *frame) {
    int rv = 0;
    http2_stream *stream;
    if (frame.hd.stream_id == 0) {
        return session_inflate_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR,
            "request HEADERS: stream_id == 0");
    }
    
    /* If client recieves idle stream from server, it is invalid
     regardless stream ID is even or odd.  This is because client is
     not expected to receive request from server. */
    if (!session.server) {
        if (session_detect_idle_stream(session, frame.hd.stream_id)) {
            return session_inflate_handle_invalid_connection(
                session, frame, http2_PROTOCOL_ERROR,
                "request HEADERS: client received request");
        }
        
        return ErrorCode.IGN_HEADER_BLOCK;
    }
    
    if (!session_is_new_peer_stream_id(session, frame.hd.stream_id)) {
        /* The spec says if an endpoint receives a HEADERS with invalid
       stream ID, it MUST issue connection error with error code
       PROTOCOL_ERROR.  But we could get trailer HEADERS after we have
       sent RST_STREAM to this stream and peer have not received it.
       Then connection error is too harsh.  It means that we only use
       connection error if stream ID refers idle stream.  OTherwise we
       just ignore HEADERS for now. */
        if (session_detect_idle_stream(session, frame.hd.stream_id)) {
            return session_inflate_handle_invalid_connection(
                session, frame, http2_PROTOCOL_ERROR,
                "request HEADERS: invalid stream_id");
        }
        
        return ErrorCode.IGN_HEADER_BLOCK;
    }
    session.last_recv_stream_id = frame.hd.stream_id;
    
    if (session.goaway_flags & http2_GOAWAY_SENT) {
        /* We just ignore stream after GOAWAY was queued */
        return ErrorCode.IGN_HEADER_BLOCK;
    }
    
    if (session_is_incoming_concurrent_streams_max(session)) {
        return session_inflate_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR,
            "request HEADERS: max concurrent streams exceeded");
    }
    
    if (frame.headers.pri_spec.stream_id == frame.hd.stream_id) {
        return session_inflate_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR,
            "request HEADERS: depend on itself");
    }
    
    if (session_is_incoming_concurrent_streams_pending_max(session)) {
        return session_inflate_handle_invalid_stream(session, frame,
            http2_REFUSED_STREAM);
    }
    
    stream = http2_session_open_stream(
        session, frame.hd.stream_id, http2_STREAM_FLAG_NONE,
        &frame.headers.pri_spec, http2_STREAM_OPENING, NULL);
    if (!stream) {
        return ErrorCode.NOMEM;
    }
    session.last_proc_stream_id = session.last_recv_stream_id;
    rv = session_call_on_begin_headers(session, frame);
    if (rv != 0) {
        return rv;
    }
    return 0;
}

int http2_session_on_response_headers_received(http2_session *session,
    http2_frame *frame,
    http2_stream *stream) {
    int rv;
    /* This function is only called if stream.state ==
     http2_STREAM_OPENING and stream_id is local side initiated. */
    assert(stream.state == http2_STREAM_OPENING &&
        http2_session_is_my_stream_id(session, frame.hd.stream_id));
    if (frame.hd.stream_id == 0) {
        return session_inflate_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR,
            "response HEADERS: stream_id == 0");
    }
    if (stream.shut_flags & http2_SHUT_RD) {
        /* half closed (remote): from the spec:

           If an endpoint receives additional frames for a stream that is
           in this state it MUST respond with a stream error (Section
           5.4.2) of type STREAM_CLOSED.
        */
        return session_inflate_handle_invalid_stream(session, frame,
            http2_STREAM_CLOSED);
    }
    stream.state = http2_STREAM_OPENED;
    rv = session_call_on_begin_headers(session, frame);
    if (rv != 0) {
        return rv;
    }
    return 0;
}

int http2_session_on_push_response_headers_received(http2_session *session,
    http2_frame *frame,
    http2_stream *stream) {
    int rv = 0;
    assert(stream.state == http2_STREAM_RESERVED);
    if (frame.hd.stream_id == 0) {
        return session_inflate_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR,
            "push response HEADERS: stream_id == 0");
    }
    if (session.goaway_flags) {
        /* We don't accept new stream after GOAWAY is sent or received. */
        return ErrorCode.IGN_HEADER_BLOCK;
    }
    
    if (session_is_incoming_concurrent_streams_max(session)) {
        return session_inflate_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR,
            "push response HEADERS: max concurrent streams exceeded");
    }
    if (session_is_incoming_concurrent_streams_pending_max(session)) {
        return session_inflate_handle_invalid_stream(session, frame,
            http2_REFUSED_STREAM);
    }
    
    http2_stream_promise_fulfilled(stream);
    ++session.num_incoming_streams;
    rv = session_call_on_begin_headers(session, frame);
    if (rv != 0) {
        return rv;
    }
    return 0;
}

int http2_session_on_headers_received(http2_session *session,
    http2_frame *frame,
    http2_stream *stream) {
    int rv = 0;
    if (frame.hd.stream_id == 0) {
        return session_inflate_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR, "HEADERS: stream_id == 0");
    }
    if (stream.state == http2_STREAM_RESERVED) {
        /* reserved. The valid push response HEADERS is processed by
       http2_session_on_push_response_headers_received(). This
       generic HEADERS is called invalid cases for HEADERS against
       reserved state. */
        return session_inflate_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR, "HEADERS: stream in reserved");
    }
    if ((stream.shut_flags & http2_SHUT_RD)) {
        /* half closed (remote): from the spec:

       If an endpoint receives additional frames for a stream that is
       in this state it MUST respond with a stream error (Section
       5.4.2) of type STREAM_CLOSED.
    */
        return session_inflate_handle_invalid_stream(session, frame,
            http2_STREAM_CLOSED);
    }
    if (http2_session_is_my_stream_id(session, frame.hd.stream_id)) {
        if (stream.state == http2_STREAM_OPENED) {
            rv = session_call_on_begin_headers(session, frame);
            if (rv != 0) {
                return rv;
            }
            return 0;
        } else if (stream.state == http2_STREAM_CLOSING) {
            /* This is race condition. http2_STREAM_CLOSING indicates
         that we queued RST_STREAM but it has not been sent. It will
         eventually sent, so we just ignore this frame. */
            return ErrorCode.IGN_HEADER_BLOCK;
        } else {
            return session_inflate_handle_invalid_stream(session, frame,
                http2_PROTOCOL_ERROR);
        }
    }
    /* If this is remote peer initiated stream, it is OK unless it
     has sent END_STREAM frame already. But if stream is in
     http2_STREAM_CLOSING, we discard the frame. This is a race
     condition. */
    if (stream.state != http2_STREAM_CLOSING) {
        rv = session_call_on_begin_headers(session, frame);
        if (rv != 0) {
            return rv;
        }
        return 0;
    }
    return ErrorCode.IGN_HEADER_BLOCK;
}

static int session_process_headers_frame(http2_session *session) {
    int rv;
    http2_inbound_frame *iframe = &session.iframe;
    http2_frame *frame = &iframe.frame;
    http2_stream *stream;
    
    rv = http2_frame_unpack_headers_payload(&frame.headers, iframe.sbuf.pos,
        http2_buf_len(&iframe.sbuf));
    
    if (rv != 0) {
        return http2_session_terminate_session_with_reason(
            session, http2_PROTOCOL_ERROR, "HEADERS: could not unpack");
    }
    stream = http2_session_get_stream(session, frame.hd.stream_id);
    if (!stream) {
        frame.headers.cat = http2_HCAT_REQUEST;
        return http2_session_on_request_headers_received(session, frame);
    }
    
    if (http2_session_is_my_stream_id(session, frame.hd.stream_id)) {
        if (stream.state == http2_STREAM_OPENING) {
            frame.headers.cat = http2_HCAT_RESPONSE;
            return http2_session_on_response_headers_received(session, frame,
                stream);
        }
        frame.headers.cat = http2_HCAT_HEADERS;
        return http2_session_on_headers_received(session, frame, stream);
    }
    if (stream.state == http2_STREAM_RESERVED) {
        frame.headers.cat = http2_HCAT_PUSH_RESPONSE;
        return http2_session_on_push_response_headers_received(session, frame,
            stream);
    }
    frame.headers.cat = http2_HCAT_HEADERS;
    return http2_session_on_headers_received(session, frame, stream);
}

int http2_session_on_priority_received(http2_session *session, http2_frame *frame) {
    int rv;
    http2_stream *stream;
    
    if (frame.hd.stream_id == 0) {
        return session_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR, "PRIORITY: stream_id == 0");
    }
    
    if (!session.server) {
        /* Re-prioritization works only in server */
        return session_call_on_frame_received(session, frame);
    }
    
    stream = http2_session_get_stream_raw(session, frame.hd.stream_id);
    
    if (!stream) {
        /* PRIORITY against idle stream can create anchor node in
       dependency tree. */
        if (!session_detect_idle_stream(session, frame.hd.stream_id)) {
            return 0;
        }
        
        stream = http2_session_open_stream(
            session, frame.hd.stream_id, http2_STREAM_FLAG_NONE,
            &frame.priority.pri_spec, http2_STREAM_IDLE, NULL);
        
        if (stream == NULL) {
            return ErrorCode.NOMEM;
        }
    } else {
        rv = http2_session_reprioritize_stream(session, stream,
            &frame.priority.pri_spec);
        
        if (http2_is_fatal(rv)) {
            return rv;
        }
    }
    
    return session_call_on_frame_received(session, frame);
}

static int session_process_priority_frame(http2_session *session) {
    http2_inbound_frame *iframe = &session.iframe;
    http2_frame *frame = &iframe.frame;
    
    http2_frame_unpack_priority_payload(&frame.priority, iframe.sbuf.pos,
        http2_buf_len(&iframe.sbuf));
    
    return http2_session_on_priority_received(session, frame);
}

int http2_session_on_rst_stream_received(http2_session *session,
    http2_frame *frame) {
    int rv;
    http2_stream *stream;
    if (frame.hd.stream_id == 0) {
        return session_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR, "RST_STREAM: stream_id == 0");
    }
    stream = http2_session_get_stream(session, frame.hd.stream_id);
    if (!stream) {
        if (session_detect_idle_stream(session, frame.hd.stream_id)) {
            return session_handle_invalid_connection(
                session, frame, http2_PROTOCOL_ERROR, "RST_STREAM: stream in idle");
        }
    }
    
    rv = session_call_on_frame_received(session, frame);
    if (rv != 0) {
        return rv;
    }
    rv = http2_session_close_stream(session, frame.hd.stream_id,
        frame.rst_stream.error_code);
    if (http2_is_fatal(rv)) {
        return rv;
    }
    return 0;
}

static int session_process_rst_stream_frame(http2_session *session) {
    http2_inbound_frame *iframe = &session.iframe;
    http2_frame *frame = &iframe.frame;
    
    http2_frame_unpack_rst_stream_payload(&frame.rst_stream, iframe.sbuf.pos,
        http2_buf_len(&iframe.sbuf));
    
    return http2_session_on_rst_stream_received(session, frame);
}

static int update_remote_initial_window_size_func(http2_map_entry *entry,
    void *ptr) {
    int rv;
    http2_update_window_size_arg *arg;
    http2_stream *stream;
    
    arg = (http2_update_window_size_arg *)ptr;
    stream = (http2_stream *)entry;
    
    rv = http2_stream_update_remote_initial_window_size(
        stream, arg.new_window_size, arg.old_window_size);
    if (rv != 0) {
        return http2_session_terminate_session(arg.session,
            http2_FLOW_CONTROL_ERROR);
    }
    
    /* If window size gets positive, push deferred DATA frame to
     outbound queue. */
    if (stream.remote_window_size > 0 &&
        http2_stream_check_deferred_by_flow_control(stream)) {
        
        rv = http2_stream_resume_deferred_item(
            stream, http2_STREAM_FLAG_DEFERRED_FLOW_CONTROL, arg.session);
        
        if (http2_is_fatal(rv)) {
            return rv;
        }
    }
    return 0;
}

/*
 * Updates the remote initial window size of all active streams.  If
 * error occurs, all streams may not be updated.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.NOMEM
 *     Out of memory.
 */
static int
    session_update_remote_initial_window_size(http2_session *session,
int new_initial_window_size) {
    http2_update_window_size_arg arg;
    
    arg.session = session;
    arg.new_window_size = new_initial_window_size;
    arg.old_window_size = session.remote_settings.initial_window_size;
    
    return http2_map_each(&session.streams,
        update_remote_initial_window_size_func, &arg);
}

static int update_local_initial_window_size_func(http2_map_entry *entry,
    void *ptr) {
    int rv;
    http2_update_window_size_arg *arg;
    http2_stream *stream;
    arg = (http2_update_window_size_arg *)ptr;
    stream = (http2_stream *)entry;
    rv = http2_stream_update_local_initial_window_size(
        stream, arg.new_window_size, arg.old_window_size);
    if (rv != 0) {
        return http2_session_terminate_session(arg.session,
            http2_FLOW_CONTROL_ERROR);
    }
    if (!(arg.session.opt_flags & http2_OPTMASK_NO_AUTO_WINDOW_UPDATE)) {
        
        if (http2_should_send_window_update(stream.local_window_size,
                stream.recv_window_size)) {
            
            rv = http2_session_add_window_update(arg.session, http2_FLAG_NONE,
                stream.stream_id,
                stream.recv_window_size);
            if (rv != 0) {
                return rv;
            }
            stream.recv_window_size = 0;
        }
    }
    return 0;
}

/*
 * Updates the local initial window size of all active streams.  If
 * error occurs, all streams may not be updated.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.NOMEM
 *     Out of memory.
 */
static int
    session_update_local_initial_window_size(http2_session *session,
        int new_initial_window_size,
int old_initial_window_size) {
    http2_update_window_size_arg arg;
    arg.session = session;
    arg.new_window_size = new_initial_window_size;
    arg.old_window_size = old_initial_window_size;
    return http2_map_each(&session.streams,
        update_local_initial_window_size_func, &arg);
}

/*
 * Apply SETTINGS values |iv| having |niv| elements to the local
 * settings.  We assumes that all values in |iv| is correct, since we
 * validated them in http2_session_add_settings() already.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.HEADER_COMP
 *     The header table size is out of range
 * ErrorCode.NOMEM
 *     Out of memory
 */
int http2_session_update_local_settings(http2_session *session,
    http2_settings_entry *iv,
    size_t niv) {
    int rv;
    size_t i;
    int new_initial_window_size = -1;
    int header_table_size = -1;
    ubyte header_table_size_seen = 0;
    /* Use the value last seen. */
    for (i = 0; i < niv; ++i) {
        switch (iv[i].settings_id) {
            case http2_SETTINGS_HEADER_TABLE_SIZE:
                header_table_size_seen = 1;
                header_table_size = iv[i].value;
                break;
            case http2_SETTINGS_INITIAL_WINDOW_SIZE:
                new_initial_window_size = iv[i].value;
                break;
        }
    }
    if (header_table_size_seen) {
        rv = http2_hd_inflate_change_table_size(&session.hd_inflater,
            header_table_size);
        if (rv != 0) {
            return rv;
        }
    }
    if (new_initial_window_size != -1) {
        rv = session_update_local_initial_window_size(
            session, new_initial_window_size,
            session.local_settings.initial_window_size);
        if (rv != 0) {
            return rv;
        }
    }
    
    for (i = 0; i < niv; ++i) {
        switch (iv[i].settings_id) {
            case http2_SETTINGS_HEADER_TABLE_SIZE:
                session.local_settings.header_table_size = iv[i].value;
                break;
            case http2_SETTINGS_ENABLE_PUSH:
                session.local_settings.enable_push = iv[i].value;
                break;
            case http2_SETTINGS_MAX_CONCURRENT_STREAMS:
                session.local_settings.max_concurrent_streams = iv[i].value;
                break;
            case http2_SETTINGS_INITIAL_WINDOW_SIZE:
                session.local_settings.initial_window_size = iv[i].value;
                break;
            case http2_SETTINGS_MAX_FRAME_SIZE:
                session.local_settings.max_frame_size = iv[i].value;
                break;
            case http2_SETTINGS_MAX_HEADER_LIST_SIZE:
                session.local_settings.max_header_list_size = iv[i].value;
                break;
        }
    }
    
    session.pending_local_max_concurrent_stream =
        http2_INITIAL_MAX_CONCURRENT_STREAMS;
    
    return 0;
}

int http2_session_on_settings_received(http2_session *session,
    http2_frame *frame, int noack) {
    int rv;
    size_t i;
    http2_mem *mem;
    
    mem = &session.mem;
    
    if (frame.hd.stream_id != 0) {
        return session_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR, "SETTINGS: stream_id != 0");
    }
    if (frame.hd.flags & http2_FLAG_ACK) {
        if (frame.settings.niv != 0) {
            return session_handle_invalid_connection(
                session, frame, http2_FRAME_SIZE_ERROR,
                "SETTINGS: ACK and payload != 0");
        }
        if (session.inflight_niv == -1) {
            return session_handle_invalid_connection(
                session, frame, http2_PROTOCOL_ERROR, "SETTINGS: unexpected ACK");
        }
        rv = http2_session_update_local_settings(session, session.inflight_iv,
            session.inflight_niv);
        http2_mem_free(mem, session.inflight_iv);
        session.inflight_iv = NULL;
        session.inflight_niv = -1;
        if (rv != 0) {
            uint error_code = http2_INTERNAL_ERROR;
            if (http2_is_fatal(rv)) {
                return rv;
            }
            if (rv == ErrorCode.HEADER_COMP) {
                error_code = http2_COMPRESSION_ERROR;
            }
            return session_handle_invalid_connection(session, frame, error_code,
                NULL);
        }
        return session_call_on_frame_received(session, frame);
    }
    
    for (i = 0; i < frame.settings.niv; ++i) {
        http2_settings_entry *entry = &frame.settings.iv[i];
        
        switch (entry.settings_id) {
            case http2_SETTINGS_HEADER_TABLE_SIZE:
                
                if (entry.value > http2_MAX_HEADER_TABLE_SIZE) {
                    return session_handle_invalid_connection(
                        session, frame, http2_COMPRESSION_ERROR,
                        "SETTINGS: too large SETTINGS_HEADER_TABLE_SIZE");
                }
                
                rv = http2_hd_deflate_change_table_size(&session.hd_deflater,
                    entry.value);
                if (rv != 0) {
                    if (http2_is_fatal(rv)) {
                        return rv;
                    } else {
                        return session_handle_invalid_connection(
                            session, frame, http2_COMPRESSION_ERROR, NULL);
                    }
                }
                
                session.remote_settings.header_table_size = entry.value;
                
                break;
            case http2_SETTINGS_ENABLE_PUSH:
                
                if (entry.value != 0 && entry.value != 1) {
                    return session_handle_invalid_connection(
                        session, frame, http2_PROTOCOL_ERROR,
                        "SETTINGS: invalid SETTINGS_ENBLE_PUSH");
                }
                
                if (!session.server && entry.value != 0) {
                    return session_handle_invalid_connection(
                        session, frame, http2_PROTOCOL_ERROR,
                        "SETTINGS: server attempted to enable push");
                }
                
                session.remote_settings.enable_push = entry.value;
                
                break;
            case http2_SETTINGS_MAX_CONCURRENT_STREAMS:
                
                session.remote_settings.max_concurrent_streams = entry.value;
                
                break;
            case http2_SETTINGS_INITIAL_WINDOW_SIZE:
                
                /* Update the initial window size of the all active streams */
                /* Check that initial_window_size < (1u << 31) */
                if (entry.value > http2_MAX_WINDOW_SIZE) {
                    return session_handle_invalid_connection(
                        session, frame, http2_FLOW_CONTROL_ERROR,
                        "SETTINGS: too large SETTINGS_INITIAL_WINDOW_SIZE");
                }
                
                rv = session_update_remote_initial_window_size(session, entry.value);
                
                if (http2_is_fatal(rv)) {
                    return rv;
                }
                
                if (rv != 0) {
                    return session_handle_invalid_connection(
                        session, frame, http2_FLOW_CONTROL_ERROR, NULL);
                }
                
                session.remote_settings.initial_window_size = entry.value;
                
                break;
            case http2_SETTINGS_MAX_FRAME_SIZE:
                
                if (entry.value < http2_MAX_FRAME_SIZE_MIN ||
                    entry.value > http2_MAX_FRAME_SIZE_MAX) {
                    return session_handle_invalid_connection(
                        session, frame, http2_PROTOCOL_ERROR,
                        "SETTINGS: invalid SETTINGS_MAX_FRAME_SIZE");
                }
                
                session.remote_settings.max_frame_size = entry.value;
                
                break;
            case http2_SETTINGS_MAX_HEADER_LIST_SIZE:
                
                session.remote_settings.max_header_list_size = entry.value;
                
                break;
        }
    }
    
    if (!noack && !session_is_closing(session)) {
        rv = http2_session_add_settings(session, http2_FLAG_ACK, NULL, 0);
        
        if (rv != 0) {
            if (http2_is_fatal(rv)) {
                return rv;
            }
            
            return session_handle_invalid_connection(session, frame,
                http2_INTERNAL_ERROR, NULL);
        }
    }
    
    return session_call_on_frame_received(session, frame);
}

static int session_process_settings_frame(http2_session *session) {
    int rv;
    http2_inbound_frame *iframe = &session.iframe;
    http2_frame *frame = &iframe.frame;
    size_t i;
    http2_settings_entry min_header_size_entry;
    http2_mem *mem;
    
    mem = &session.mem;
    min_header_size_entry = iframe.iv[http2_INBOUND_NUM_IV - 1];
    
    if (min_header_size_entry.value < UINT32_MAX) {
        /* If we have less value, then we must have
       SETTINGS_HEADER_TABLE_SIZE in i < iframe.niv */
        for (i = 0; i < iframe.niv; ++i) {
            if (iframe.iv[i].settings_id == http2_SETTINGS_HEADER_TABLE_SIZE) {
                break;
            }
        }
        
        assert(i < iframe.niv);
        
        if (min_header_size_entry.value != iframe.iv[i].value) {
            iframe.iv[iframe.niv++] = iframe.iv[i];
            iframe.iv[i] = min_header_size_entry;
        }
    }
    
    rv = http2_frame_unpack_settings_payload(&frame.settings, iframe.iv,
        iframe.niv, mem);
    if (rv != 0) {
        assert(http2_is_fatal(rv));
        return rv;
    }
    return http2_session_on_settings_received(session, frame, 0 /* ACK */);
}

int http2_session_on_push_promise_received(http2_session *session,
    http2_frame *frame) {
    int rv;
    http2_stream *stream;
    http2_stream *promised_stream;
    http2_priority_spec pri_spec;
    
    if (frame.hd.stream_id == 0) {
        return session_inflate_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR, "PUSH_PROMISE: stream_id == 0");
    }
    if (session.server || session.local_settings.enable_push == 0) {
        return session_inflate_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR, "PUSH_PROMISE: push disabled");
    }
    if (session.goaway_flags) {
        /* We just dicard PUSH_PROMISE after GOAWAY is sent or
       received. */
        return ErrorCode.IGN_HEADER_BLOCK;
    }
    
    if (!http2_session_is_my_stream_id(session, frame.hd.stream_id)) {
        return session_inflate_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR,
            "PUSH_PROMISE: invalid stream_id");
    }
    
    if (!session_is_new_peer_stream_id(session,
            frame.push_promise.promised_stream_id)) {
        /* The spec says if an endpoint receives a PUSH_PROMISE with
       illegal stream ID is subject to a connection error of type
       PROTOCOL_ERROR. */
        return session_inflate_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR,
            "PUSH_PROMISE: invalid promised_stream_id");
    }
    session.last_recv_stream_id = frame.push_promise.promised_stream_id;
    stream = http2_session_get_stream(session, frame.hd.stream_id);
    if (!stream || stream.state == http2_STREAM_CLOSING) {
        if (!stream) {
            if (session_detect_idle_stream(session, frame.hd.stream_id)) {
                return session_inflate_handle_invalid_connection(
                    session, frame, http2_PROTOCOL_ERROR,
                    "PUSH_PROMISE: stream in idle");
            }
        }
        rv = http2_session_add_rst_stream(session,
            frame.push_promise.promised_stream_id,
            http2_REFUSED_STREAM);
        if (rv != 0) {
            return rv;
        }
        return ErrorCode.IGN_HEADER_BLOCK;
    }
    if (stream.shut_flags & http2_SHUT_RD) {
        if (session.callbacks.on_invalid_frame_recv_callback) {
            if (session.callbacks.on_invalid_frame_recv_callback(
                    session, frame, http2_PROTOCOL_ERROR, session.user_data) !=
                0) {
                return ErrorCode.CALLBACK_FAILURE;
            }
        }
        rv = http2_session_add_rst_stream(session,
            frame.push_promise.promised_stream_id,
            http2_PROTOCOL_ERROR);
        if (rv != 0) {
            return rv;
        }
        return ErrorCode.IGN_HEADER_BLOCK;
    }
    
    /* TODO It is unclear reserved stream dpeneds on associated
     stream with or without exclusive flag set */
    http2_priority_spec_init(&pri_spec, stream.stream_id,
        http2_DEFAULT_WEIGHT, 0);
    
    promised_stream = http2_session_open_stream(
        session, frame.push_promise.promised_stream_id, http2_STREAM_FLAG_NONE,
        &pri_spec, http2_STREAM_RESERVED, NULL);
    
    if (!promised_stream) {
        return ErrorCode.NOMEM;
    }
    
    session.last_proc_stream_id = session.last_recv_stream_id;
    rv = session_call_on_begin_headers(session, frame);
    if (rv != 0) {
        return rv;
    }
    return 0;
}

static int session_process_push_promise_frame(http2_session *session) {
    int rv;
    http2_inbound_frame *iframe = &session.iframe;
    http2_frame *frame = &iframe.frame;
    
    rv = http2_frame_unpack_push_promise_payload(
        &frame.push_promise, iframe.sbuf.pos, http2_buf_len(&iframe.sbuf));
    
    if (rv != 0) {
        return http2_session_terminate_session_with_reason(
            session, http2_PROTOCOL_ERROR, "PUSH_PROMISE: could not unpack");
    }
    
    return http2_session_on_push_promise_received(session, frame);
}

int http2_session_on_ping_received(http2_session *session,
    http2_frame *frame) {
    int rv = 0;
    if (frame.hd.stream_id != 0) {
        return session_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR, "PING: stream_id != 0");
    }
    if ((frame.hd.flags & http2_FLAG_ACK) == 0 &&
        !session_is_closing(session)) {
        /* Peer sent ping, so ping it back */
        rv = http2_session_add_ping(session, http2_FLAG_ACK,
            frame.ping.opaque_data);
        if (rv != 0) {
            return rv;
        }
    }
    return session_call_on_frame_received(session, frame);
}

static int session_process_ping_frame(http2_session *session) {
    http2_inbound_frame *iframe = &session.iframe;
    http2_frame *frame = &iframe.frame;
    
    http2_frame_unpack_ping_payload(&frame.ping, iframe.sbuf.pos,
        http2_buf_len(&iframe.sbuf));
    
    return http2_session_on_ping_received(session, frame);
}

int http2_session_on_goaway_received(http2_session *session,
    http2_frame *frame) {
    int rv;
    
    if (frame.hd.stream_id != 0) {
        return session_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR, "GOAWAY: stream_id != 0");
    }
    /* Spec says Endpoints MUST NOT increase the value they send in the
     last stream identifier. */
    if ((frame.goaway.last_stream_id > 0 &&
            !http2_session_is_my_stream_id(session,
                frame.goaway.last_stream_id)) ||
        session.remote_last_stream_id < frame.goaway.last_stream_id) {
        return session_handle_invalid_connection(session, frame,
            http2_PROTOCOL_ERROR,
            "GOAWAY: invalid last_stream_id");
    }
    
    session.goaway_flags |= http2_GOAWAY_RECV;
    
    session.remote_last_stream_id = frame.goaway.last_stream_id;
    
    rv = session_call_on_frame_received(session, frame);
    
    if (http2_is_fatal(rv)) {
        return rv;
    }
    
    return session_close_stream_on_goaway(session, frame.goaway.last_stream_id,
        0);
}

static int session_process_goaway_frame(http2_session *session) {
    http2_inbound_frame *iframe = &session.iframe;
    http2_frame *frame = &iframe.frame;
    
    http2_frame_unpack_goaway_payload(
        &frame.goaway, iframe.sbuf.pos, http2_buf_len(&iframe.sbuf),
        iframe.lbuf.pos, http2_buf_len(&iframe.lbuf));
    
    http2_buf_wrap_init(&iframe.lbuf, NULL, 0);
    
    return http2_session_on_goaway_received(session, frame);
}

static int
    session_on_connection_window_update_received(http2_session *session,
http2_frame *frame) {
    /* Handle connection-level flow control */
    if (frame.window_update.window_size_increment == 0) {
        return session_handle_invalid_connection(session, frame,
            http2_PROTOCOL_ERROR, NULL);
    }
    
    if (http2_MAX_WINDOW_SIZE - frame.window_update.window_size_increment <
        session.remote_window_size) {
        return session_handle_invalid_connection(session, frame,
            http2_FLOW_CONTROL_ERROR, NULL);
    }
    session.remote_window_size += frame.window_update.window_size_increment;
    
    return session_call_on_frame_received(session, frame);
}

static int session_on_stream_window_update_received(http2_session *session,
    http2_frame *frame) {
    int rv;
    http2_stream *stream;
    stream = http2_session_get_stream(session, frame.hd.stream_id);
    if (!stream) {
        if (session_detect_idle_stream(session, frame.hd.stream_id)) {
            return session_handle_invalid_connection(session, frame,
                http2_PROTOCOL_ERROR,
                "WINDOW_UPDATE to idle stream");
        }
        return 0;
    }
    if (state_reserved_remote(session, stream)) {
        return session_handle_invalid_connection(
            session, frame, http2_PROTOCOL_ERROR,
            "WINDOW_UPADATE to reserved stream");
    }
    if (frame.window_update.window_size_increment == 0) {
        return session_handle_invalid_stream(session, frame,
            http2_PROTOCOL_ERROR);
    }
    if (http2_MAX_WINDOW_SIZE - frame.window_update.window_size_increment <
        stream.remote_window_size) {
        return session_handle_invalid_stream(session, frame,
            http2_FLOW_CONTROL_ERROR);
    }
    stream.remote_window_size += frame.window_update.window_size_increment;
    
    if (stream.remote_window_size > 0 &&
        http2_stream_check_deferred_by_flow_control(stream)) {
        
        rv = http2_stream_resume_deferred_item(
            stream, http2_STREAM_FLAG_DEFERRED_FLOW_CONTROL, session);
        
        if (http2_is_fatal(rv)) {
            return rv;
        }
    }
    return session_call_on_frame_received(session, frame);
}

int http2_session_on_window_update_received(http2_session *session,
    http2_frame *frame) {
    if (frame.hd.stream_id == 0) {
        return session_on_connection_window_update_received(session, frame);
    } else {
        return session_on_stream_window_update_received(session, frame);
    }
}

static int session_process_window_update_frame(http2_session *session) {
    http2_inbound_frame *iframe = &session.iframe;
    http2_frame *frame = &iframe.frame;
    
    http2_frame_unpack_window_update_payload(
        &frame.window_update, iframe.sbuf.pos, http2_buf_len(&iframe.sbuf));
    
    return http2_session_on_window_update_received(session, frame);
}

/* static int get_error_code_from_lib_error_code(int lib_error_code) */
/* { */
/*   switch(lib_error_code) { */
/*   case ErrorCode.HEADER_COMP: */
/*     return http2_COMPRESSION_ERROR; */
/*   case ErrorCode.FRAME_SIZE_ERROR: */
/*     return http2_FRAME_SIZE_ERROR; */
/*   default: */
/*     return http2_PROTOCOL_ERROR; */
/*   } */
/* } */

int http2_session_on_data_received(http2_session *session,
    http2_frame *frame) {
    int rv = 0;
    int call_cb = 1;
    http2_stream *stream;
    
    /* We don't call on_frame_recv_callback if stream has been closed
     already or being closed. */
    stream = http2_session_get_stream(session, frame.hd.stream_id);
    if (!stream || stream.state == http2_STREAM_CLOSING) {
        /* This should be treated as stream error, but it results in lots
       of RST_STREAM. So just ignore frame against nonexistent stream
       for now. */
        return 0;
    }
    
    if (session_enforce_http_messaging(session) &&
        (frame.hd.flags & http2_FLAG_END_STREAM)) {
        if (http2_http_on_remote_end_stream(stream) != 0) {
            call_cb = 0;
            rv = http2_session_add_rst_stream(session, stream.stream_id,
                http2_PROTOCOL_ERROR);
            if (http2_is_fatal(rv)) {
                return rv;
            }
        }
    }
    
    if (call_cb) {
        rv = session_call_on_frame_received(session, frame);
        if (http2_is_fatal(rv)) {
            return rv;
        }
    }
    
    if (frame.hd.flags & http2_FLAG_END_STREAM) {
        http2_stream_shutdown(stream, http2_SHUT_RD);
        rv = http2_session_close_stream_if_shut_rdwr(session, stream);
        if (http2_is_fatal(rv)) {
            return rv;
        }
    }
    return 0;
}

/* For errors, this function only returns FATAL error. */
static int session_process_data_frame(http2_session *session) {
    int rv;
    http2_frame *public_data_frame = &session.iframe.frame;
    rv = http2_session_on_data_received(session, public_data_frame);
    if (http2_is_fatal(rv)) {
        return rv;
    }
    return 0;
}

/*
 * Now we have SETTINGS synchronization, flow control error can be
 * detected strictly. If DATA frame is received with length > 0 and
 * current received window size + delta length is strictly larger than
 * local window size, it is subject to FLOW_CONTROL_ERROR, so return
 * -1. Note that local_window_size is calculated after SETTINGS ACK is
 * received from peer, so peer must honor this limit. If the resulting
 * recv_window_size is strictly larger than http2_MAX_WINDOW_SIZE,
 * return -1 too.
 */
static int adjust_recv_window_size(int *recv_window_size_ptr, size_t delta,
    int local_window_size) {
    if (*recv_window_size_ptr > local_window_size - (int)delta ||
        *recv_window_size_ptr > http2_MAX_WINDOW_SIZE - (int)delta) {
        return -1;
    }
    *recv_window_size_ptr += delta;
    return 0;
}

/*
 * Accumulates received bytes |delta_size| for stream-level flow
 * control and decides whether to send WINDOW_UPDATE to that stream.
 * If http2_OPT_NO_AUTO_WINDOW_UPDATE is set, WINDOW_UPDATE will not
 * be sent.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.NOMEM
 *     Out of memory.
 */
static int session_update_recv_stream_window_size(http2_session *session,
    http2_stream *stream,
    size_t delta_size,
    int send_window_update) {
    int rv;
    rv = adjust_recv_window_size(&stream.recv_window_size, delta_size,
        stream.local_window_size);
    if (rv != 0) {
        return http2_session_add_rst_stream(session, stream.stream_id,
            http2_FLOW_CONTROL_ERROR);
    }
    /* We don't have to send WINDOW_UPDATE if the data received is the
     last chunk in the incoming stream. */
    if (send_window_update &&
        !(session.opt_flags & http2_OPTMASK_NO_AUTO_WINDOW_UPDATE)) {
        /* We have to use local_settings here because it is the constraint
       the remote endpoint should honor. */
        if (http2_should_send_window_update(stream.local_window_size,
                stream.recv_window_size)) {
            rv = http2_session_add_window_update(session, http2_FLAG_NONE,
                stream.stream_id,
                stream.recv_window_size);
            if (rv == 0) {
                stream.recv_window_size = 0;
            } else {
                return rv;
            }
        }
    }
    return 0;
}

/*
 * Accumulates received bytes |delta_size| for connection-level flow
 * control and decides whether to send WINDOW_UPDATE to the
 * connection.  If http2_OPT_NO_AUTO_WINDOW_UPDATE is set,
 * WINDOW_UPDATE will not be sent.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.NOMEM
 *     Out of memory.
 */
static int session_update_recv_connection_window_size(http2_session *session,
    size_t delta_size) {
    int rv;
    rv = adjust_recv_window_size(&session.recv_window_size, delta_size,
        session.local_window_size);
    if (rv != 0) {
        return http2_session_terminate_session(session,
            http2_FLOW_CONTROL_ERROR);
    }
    if (!(session.opt_flags & http2_OPTMASK_NO_AUTO_WINDOW_UPDATE)) {
        
        if (http2_should_send_window_update(session.local_window_size,
                session.recv_window_size)) {
            /* Use stream ID 0 to update connection-level flow control
         window */
            rv = http2_session_add_window_update(session, http2_FLAG_NONE, 0,
                session.recv_window_size);
            if (rv != 0) {
                return rv;
            }
            
            session.recv_window_size = 0;
        }
    }
    return 0;
}

static int session_update_consumed_size(http2_session *session,
    int *consumed_size_ptr,
    int *recv_window_size_ptr,
    int stream_id, size_t delta_size,
    int local_window_size) {
    int recv_size;
    int rv;
    
    if ((size_t)*consumed_size_ptr > http2_MAX_WINDOW_SIZE - delta_size) {
        return http2_session_terminate_session(session,
            http2_FLOW_CONTROL_ERROR);
    }
    
    *consumed_size_ptr += delta_size;
    
    /* recv_window_size may be smaller than consumed_size, because it
     may be decreased by negative value with
     http2_submit_window_update(). */
    recv_size = http2_min(*consumed_size_ptr, *recv_window_size_ptr);
    
    if (http2_should_send_window_update(local_window_size, recv_size)) {
        rv = http2_session_add_window_update(session, http2_FLAG_NONE,
            stream_id, recv_size);
        
        if (rv != 0) {
            return rv;
        }
        
        *recv_window_size_ptr -= recv_size;
        *consumed_size_ptr -= recv_size;
    }
    
    return 0;
}

static int session_update_stream_consumed_size(http2_session *session,
    http2_stream *stream,
    size_t delta_size) {
    return session_update_consumed_size(
        session, &stream.consumed_size, &stream.recv_window_size,
        stream.stream_id, delta_size, stream.local_window_size);
}

static int session_update_connection_consumed_size(http2_session *session,
    size_t delta_size) {
    return session_update_consumed_size(session, &session.consumed_size,
        &session.recv_window_size, 0, delta_size,
        session.local_window_size);
}

/*
 * Checks that we can receive the DATA frame for stream, which is
 * indicated by |session.iframe.frame.hd.stream_id|. If it is a
 * connection error situation, GOAWAY frame will be issued by this
 * function.
 *
 * If the DATA frame is allowed, returns 0.
 *
 * This function returns 0 if it succeeds, or one of the following
 * negative error codes:
 *
 * ErrorCode.IGN_PAYLOAD
 *   The reception of DATA frame is connection error; or should be
 *   ignored.
 * ErrorCode.NOMEM
 *   Out of memory.
 */
static int session_on_data_received_fail_fast(http2_session *session) {
    int rv;
    http2_stream *stream;
    http2_inbound_frame *iframe;
    int stream_id;
    const char *failure_reason;
    uint error_code = http2_PROTOCOL_ERROR;
    
    iframe = &session.iframe;
    stream_id = iframe.frame.hd.stream_id;
    
    if (stream_id == 0) {
        /* The spec says that if a DATA frame is received whose stream ID
       is 0, the recipient MUST respond with a connection error of
       type PROTOCOL_ERROR. */
        failure_reason = "DATA: stream_id == 0";
        goto fail;
    }
    stream = http2_session_get_stream(session, stream_id);
    if (!stream) {
        if (session_detect_idle_stream(session, stream_id)) {
            failure_reason = "DATA: stream in idle";
            error_code = http2_STREAM_CLOSED;
            goto fail;
        }
        return ErrorCode.IGN_PAYLOAD;
    }
    if (stream.shut_flags & http2_SHUT_RD) {
        failure_reason = "DATA: stream in half-closed(remote)";
        error_code = http2_STREAM_CLOSED;
        goto fail;
    }
    
    if (http2_session_is_my_stream_id(session, stream_id)) {
        if (stream.state == http2_STREAM_CLOSING) {
            return ErrorCode.IGN_PAYLOAD;
        }
        if (stream.state != http2_STREAM_OPENED) {
            failure_reason = "DATA: stream not opened";
            goto fail;
        }
        return 0;
    }
    if (stream.state == http2_STREAM_RESERVED) {
        failure_reason = "DATA: stream in reserved";
        goto fail;
    }
    if (stream.state == http2_STREAM_CLOSING) {
        return ErrorCode.IGN_PAYLOAD;
    }
    return 0;
fail:
    rv = http2_session_terminate_session_with_reason(session, error_code,
        failure_reason);
    if (http2_is_fatal(rv)) {
        return rv;
    }
    return ErrorCode.IGN_PAYLOAD;
}

static size_t inbound_frame_payload_readlen(http2_inbound_frame *iframe,
    const ubyte *in,
    const ubyte *last) {
    return http2_min((size_t)(last - in), iframe.payloadleft);
}

/*
 * Resets iframe.sbuf and advance its mark pointer by |left| bytes.
 */
static void inbound_frame_set_mark(http2_inbound_frame *iframe, size_t left) {
    http2_buf_reset(&iframe.sbuf);
    iframe.sbuf.mark += left;
}

static size_t inbound_frame_buf_read(http2_inbound_frame *iframe,
    const ubyte *input, const ubyte *last) {
    size_t readlen;
    
    readlen = http2_min(last - input, http2_buf_mark_avail(&iframe.sbuf));
    
    iframe.sbuf.last = http2_cpymem(iframe.sbuf.last, input, readlen);
    
    return readlen;
}

/*
 * Unpacks SETTINGS entry in iframe.sbuf.
 */
static void inbound_frame_set_settings_entry(http2_inbound_frame *iframe) {
    http2_settings_entry iv;
    size_t i;
    
    http2_frame_unpack_settings_entry(&iv, iframe.sbuf.pos);
    
    switch (iv.settings_id) {
        case http2_SETTINGS_HEADER_TABLE_SIZE:
        case http2_SETTINGS_ENABLE_PUSH:
        case http2_SETTINGS_MAX_CONCURRENT_STREAMS:
        case http2_SETTINGS_INITIAL_WINDOW_SIZE:
        case http2_SETTINGS_MAX_FRAME_SIZE:
        case http2_SETTINGS_MAX_HEADER_LIST_SIZE:
            break;
        default:
            DEBUGF(fprintf(stderr, "recv: ignore unknown settings id=0x%02x\n",
                    iv.settings_id));
            return;
    }
    
    for (i = 0; i < iframe.niv; ++i) {
        if (iframe.iv[i].settings_id == iv.settings_id) {
            iframe.iv[i] = iv;
            break;
        }
    }
    
    if (i == iframe.niv) {
        iframe.iv[iframe.niv++] = iv;
    }
    
    if (iv.settings_id == http2_SETTINGS_HEADER_TABLE_SIZE &&
        iv.value < iframe.iv[http2_INBOUND_NUM_IV - 1].value) {
        
        iframe.iv[http2_INBOUND_NUM_IV - 1] = iv;
    }
}

/*
 * Checks PADDED flags and set iframe.sbuf to read them accordingly.
 * If padding is set, this function returns 1.  If no padding is set,
 * this function returns 0.  On error, returns -1.
 */
static int inbound_frame_handle_pad(http2_inbound_frame *iframe, http2_frame_hd *hd) {
    if (hd.flags & http2_FLAG_PADDED) {
        if (hd.length < 1) {
            return -1;
        }
        inbound_frame_set_mark(iframe, 1);
        return 1;
    }
    DEBUGF(fprintf(stderr, "recv: no padding in payload\n"));
    return 0;
}

/*
 * Computes number of padding based on flags. This function returns
 * the calculated length if it succeeds, or -1.
 */
static size_t inbound_frame_compute_pad(http2_inbound_frame *iframe) {
    size_t padlen;
    
    /* 1 for Pad Length field */
    padlen = iframe.sbuf.pos[0] + 1;
    
    DEBUGF(fprintf(stderr, "recv: padlen=%zu\n", padlen));
    
    /* We cannot use iframe.frame.hd.length because of CONTINUATION */
    if (padlen - 1 > iframe.payloadleft) {
        return -1;
    }
    
    iframe.padlen = padlen;
    
    return padlen;
}

/*
 * This function returns the effective payload length in the data of
 * length |readlen| when the remaning payload is |payloadleft|. The
 * |payloadleft| does not include |readlen|. If padding was started
 * strictly before this data chunk, this function returns -1.
 */
static size_t inbound_frame_effective_readlen(http2_inbound_frame *iframe,
    size_t payloadleft,
    size_t readlen) {
    size_t trail_padlen =
        http2_frame_trail_padlen(&iframe.frame, iframe.padlen);
    
    if (trail_padlen > payloadleft) {
        size_t padlen;
        padlen = trail_padlen - payloadleft;
        if (readlen < padlen) {
            return -1;
        } else {
            return readlen - padlen;
        }
    }
    return readlen;
}

size_t http2_session_mem_recv(http2_session *session, const ubyte *input, size_t inlen) {
    const ubyte *first = input, *last = input + inlen;
    http2_inbound_frame *iframe = &session.iframe;
    size_t readlen;
    size_t padlen;
    int rv;
    int busy = 0;
    http2_frame_hd cont_hd;
    http2_stream *stream;
    size_t pri_fieldlen;
    http2_mem *mem;
    
    DEBUGF(fprintf(stderr,
            "recv: connection recv_window_size=%d, local_window=%d\n",
            session.recv_window_size, session.local_window_size));
    
    mem = &session.mem;
    
    for (;;) {
        switch (iframe.state) {
            case http2_IB_READ_CLIENT_PREFACE:
                readlen = http2_min(inlen, iframe.payloadleft);
                
                if (memcmp(http2_CLIENT_CONNECTION_PREFACE +
                        http2_CLIENT_CONNECTION_PREFACE_LEN -
                        iframe.payloadleft,
                        input, readlen) != 0) {
                    return ErrorCode.BAD_PREFACE;
                }
                
                iframe.payloadleft -= readlen;
                input += readlen;
                
                if (iframe.payloadleft == 0) {
                    session_inbound_frame_reset(session);
                    iframe.state = http2_IB_READ_FIRST_SETTINGS;
                }
                
                break;
            case http2_IB_READ_FIRST_SETTINGS:
                DEBUGF(fprintf(stderr, "recv: [IB_READ_FIRST_SETTINGS]\n"));
                
                readlen = inbound_frame_buf_read(iframe, input, last);
                input += readlen;
                
                if (http2_buf_mark_avail(&iframe.sbuf)) {
                    return in - first;
                }
                
                if (iframe.sbuf.pos[3] != http2_SETTINGS ||
                    (iframe.sbuf.pos[4] & http2_FLAG_ACK)) {
                    
                    iframe.state = http2_IB_IGN_ALL;
                    
                    rv = http2_session_terminate_session_with_reason(
                        session, http2_PROTOCOL_ERROR, "SETTINGS expected");
                    
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                    
                    return inlen;
                }
                
                iframe.state = http2_IB_READ_HEAD;
                
                /* Fall through */
            case http2_IB_READ_HEAD: {
                int on_begin_frame_called = 0;
                
                DEBUGF(fprintf(stderr, "recv: [IB_READ_HEAD]\n"));
                
                readlen = inbound_frame_buf_read(iframe, input, last);
                input += readlen;
                
                if (http2_buf_mark_avail(&iframe.sbuf)) {
                    return in - first;
                }
                
                http2_frame_unpack_frame_hd(&iframe.frame.hd, iframe.sbuf.pos);
                iframe.payloadleft = iframe.frame.hd.length;
                
                DEBUGF(fprintf(stderr, "recv: payloadlen=%zu, type=%u, flags=0x%02x, "
                        "stream_id=%d\n",
                        iframe.frame.hd.length, iframe.frame.hd.type,
                        iframe.frame.hd.flags, iframe.frame.hd.stream_id));
                
                if (iframe.frame.hd.length > session.local_settings.max_frame_size) {
                    DEBUGF(fprintf(stderr, "recv: length is too large %zu > %u\n",
                            iframe.frame.hd.length,
                            session.local_settings.max_frame_size));
                    
                    busy = 1;
                    
                    iframe.state = http2_IB_IGN_PAYLOAD;
                    
                    rv = http2_session_terminate_session_with_reason(
                        session, http2_FRAME_SIZE_ERROR, "too large frame size");
                    
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                    
                    break;
                }
                
                switch (iframe.frame.hd.type) {
                    case http2_DATA: {
                        DEBUGF(fprintf(stderr, "recv: DATA\n"));
                        
                        iframe.frame.hd.flags &=
                            (http2_FLAG_END_STREAM | http2_FLAG_PADDED);
                        /* Check stream is open. If it is not open or closing,
                           ignore payload. */
                        busy = 1;
                        
                        rv = session_on_data_received_fail_fast(session);
                        if (rv == ErrorCode.IGN_PAYLOAD) {
                            DEBUGF(fprintf(stderr, "recv: DATA not allowed stream_id=%d\n",
                                    iframe.frame.hd.stream_id));
                            iframe.state = http2_IB_IGN_DATA;
                            break;
                        }
                        
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                        
                        rv = inbound_frame_handle_pad(iframe, &iframe.frame.hd);
                        if (rv < 0) {
                            iframe.state = http2_IB_IGN_DATA;
                            rv = http2_session_terminate_session_with_reason(
                                session, http2_PROTOCOL_ERROR,
                                "DATA: insufficient padding space");
                            
                            if (http2_is_fatal(rv)) {
                                return rv;
                            }
                            break;
                        }
                        
                        if (rv == 1) {
                            iframe.state = http2_IB_READ_PAD_DATA;
                            break;
                        }
                        
                        iframe.state = http2_IB_READ_DATA;
                        break;
                    }
                    case http2_HEADERS:
                        
                        DEBUGF(fprintf(stderr, "recv: HEADERS\n"));
                        
                        iframe.frame.hd.flags &=
                            (http2_FLAG_END_STREAM | http2_FLAG_END_HEADERS |
                                http2_FLAG_PADDED | http2_FLAG_PRIORITY);
                        
                        rv = inbound_frame_handle_pad(iframe, &iframe.frame.hd);
                        if (rv < 0) {
                            busy = 1;
                            
                            iframe.state = http2_IB_IGN_PAYLOAD;
                            
                            rv = http2_session_terminate_session_with_reason(
                                session, http2_PROTOCOL_ERROR,
                                "HEADERS: insufficient padding space");
                            if (http2_is_fatal(rv)) {
                                return rv;
                            }
                            break;
                        }
                        
                        if (rv == 1) {
                            iframe.state = http2_IB_READ_NBYTE;
                            break;
                        }
                        
                        pri_fieldlen = http2_frame_priority_len(iframe.frame.hd.flags);
                        
                        if (pri_fieldlen > 0) {
                            if (iframe.payloadleft < pri_fieldlen) {
                                busy = 1;
                                iframe.state = http2_IB_FRAME_SIZE_ERROR;
                                break;
                            }
                            
                            iframe.state = http2_IB_READ_NBYTE;
                            
                            inbound_frame_set_mark(iframe, pri_fieldlen);
                            
                            break;
                        }
                        
                        /* Call on_begin_frame_callback here because
                           session_process_headers_frame() may call
                           on_begin_headers_callback */
                        rv = session_call_on_begin_frame(session, &iframe.frame.hd);
                        
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                        
                        on_begin_frame_called = 1;
                        
                        rv = session_process_headers_frame(session);
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                        
                        busy = 1;
                        
                        if (rv == ErrorCode.IGN_HEADER_BLOCK) {
                            iframe.state = http2_IB_IGN_HEADER_BLOCK;
                            break;
                        }
                        
                        iframe.state = http2_IB_READ_HEADER_BLOCK;
                        
                        break;
                    case http2_PRIORITY:
                        DEBUGF(fprintf(stderr, "recv: PRIORITY\n"));
                        
                        iframe.frame.hd.flags = http2_FLAG_NONE;
                        
                        if (iframe.payloadleft != http2_PRIORITY_SPECLEN) {
                            busy = 1;
                            
                            iframe.state = http2_IB_FRAME_SIZE_ERROR;
                            
                            break;
                        }
                        
                        iframe.state = http2_IB_READ_NBYTE;
                        
                        inbound_frame_set_mark(iframe, http2_PRIORITY_SPECLEN);
                        
                        break;
                    case http2_RST_STREAM:
                    case http2_WINDOW_UPDATE:
#ifdef DEBUGBUILD
                        switch (iframe.frame.hd.type) {
                            case http2_RST_STREAM:
                                DEBUGF(fprintf(stderr, "recv: RST_STREAM\n"));
                                break;
                            case http2_WINDOW_UPDATE:
                                DEBUGF(fprintf(stderr, "recv: WINDOW_UPDATE\n"));
                                break;
                        }
#endif /* DEBUGBUILD */
                        
                        iframe.frame.hd.flags = http2_FLAG_NONE;
                        
                        if (iframe.payloadleft != 4) {
                            busy = 1;
                            iframe.state = http2_IB_FRAME_SIZE_ERROR;
                            break;
                        }
                        
                        iframe.state = http2_IB_READ_NBYTE;
                        
                        inbound_frame_set_mark(iframe, 4);
                        
                        break;
                    case http2_SETTINGS:
                        DEBUGF(fprintf(stderr, "recv: SETTINGS\n"));
                        
                        iframe.frame.hd.flags &= http2_FLAG_ACK;
                        
                        if ((iframe.frame.hd.length % http2_FRAME_SETTINGS_ENTRY_LENGTH) ||
                            ((iframe.frame.hd.flags & http2_FLAG_ACK) &&
                                iframe.payloadleft > 0)) {
                            busy = 1;
                            iframe.state = http2_IB_FRAME_SIZE_ERROR;
                            break;
                        }
                        
                        iframe.state = http2_IB_READ_SETTINGS;
                        
                        if (iframe.payloadleft) {
                            inbound_frame_set_mark(iframe, http2_FRAME_SETTINGS_ENTRY_LENGTH);
                            break;
                        }
                        
                        busy = 1;
                        
                        inbound_frame_set_mark(iframe, 0);
                        
                        break;
                    case http2_PUSH_PROMISE:
                        DEBUGF(fprintf(stderr, "recv: PUSH_PROMISE\n"));
                        
                        iframe.frame.hd.flags &=
                            (http2_FLAG_END_HEADERS | http2_FLAG_PADDED);
                        
                        rv = inbound_frame_handle_pad(iframe, &iframe.frame.hd);
                        if (rv < 0) {
                            busy = 1;
                            iframe.state = http2_IB_IGN_PAYLOAD;
                            rv = http2_session_terminate_session_with_reason(
                                session, http2_PROTOCOL_ERROR,
                                "PUSH_PROMISE: insufficient padding space");
                            if (http2_is_fatal(rv)) {
                                return rv;
                            }
                            break;
                        }
                        
                        if (rv == 1) {
                            iframe.state = http2_IB_READ_NBYTE;
                            break;
                        }
                        
                        if (iframe.payloadleft < 4) {
                            busy = 1;
                            iframe.state = http2_IB_FRAME_SIZE_ERROR;
                            break;
                        }
                        
                        iframe.state = http2_IB_READ_NBYTE;
                        
                        inbound_frame_set_mark(iframe, 4);
                        
                        break;
                    case http2_PING:
                        DEBUGF(fprintf(stderr, "recv: PING\n"));
                        
                        iframe.frame.hd.flags &= http2_FLAG_ACK;
                        
                        if (iframe.payloadleft != 8) {
                            busy = 1;
                            iframe.state = http2_IB_FRAME_SIZE_ERROR;
                            break;
                        }
                        
                        iframe.state = http2_IB_READ_NBYTE;
                        inbound_frame_set_mark(iframe, 8);
                        
                        break;
                    case http2_GOAWAY:
                        DEBUGF(fprintf(stderr, "recv: GOAWAY\n"));
                        
                        iframe.frame.hd.flags = http2_FLAG_NONE;
                        
                        if (iframe.payloadleft < 8) {
                            busy = 1;
                            iframe.state = http2_IB_FRAME_SIZE_ERROR;
                            break;
                        }
                        
                        iframe.state = http2_IB_READ_NBYTE;
                        inbound_frame_set_mark(iframe, 8);
                        
                        break;
                    case http2_CONTINUATION:
                        DEBUGF(fprintf(stderr, "recv: unexpected CONTINUATION\n"));
                        
                        /* Receiving CONTINUATION in this state are subject to
           connection error of type PROTOCOL_ERROR */
                        rv = http2_session_terminate_session_with_reason(
                            session, http2_PROTOCOL_ERROR, "CONTINUATION: unexpected");
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                        
                        busy = 1;
                        
                        iframe.state = http2_IB_IGN_PAYLOAD;
                        
                        break;
                    default:
                        DEBUGF(fprintf(stderr, "recv: unknown frame\n"));
                        
                        /* Silently ignore unknown frame type. */
                        
                        busy = 1;
                        
                        iframe.state = http2_IB_IGN_PAYLOAD;
                        
                        break;
                }
                
                if (!on_begin_frame_called) {
                    switch (iframe.state) {
                        case http2_IB_IGN_HEADER_BLOCK:
                        case http2_IB_IGN_PAYLOAD:
                        case http2_IB_FRAME_SIZE_ERROR:
                        case http2_IB_IGN_DATA:
                            break;
                        default:
                            rv = session_call_on_begin_frame(session, &iframe.frame.hd);
                            
                            if (http2_is_fatal(rv)) {
                                return rv;
                            }
                    }
                }
                
                break;
            }
            case http2_IB_READ_NBYTE:
                DEBUGF(fprintf(stderr, "recv: [IB_READ_NBYTE]\n"));
                
                readlen = inbound_frame_buf_read(iframe, input, last);
                input += readlen;
                iframe.payloadleft -= readlen;
                
                DEBUGF(fprintf(stderr, "recv: readlen=%zu, payloadleft=%zu, left=%zd\n",
                        readlen, iframe.payloadleft,
                        http2_buf_mark_avail(&iframe.sbuf)));
                
                if (http2_buf_mark_avail(&iframe.sbuf)) {
                    return in - first;
                }
                
                switch (iframe.frame.hd.type) {
                    case http2_HEADERS:
                        if (iframe.padlen == 0 &&
                            (iframe.frame.hd.flags & http2_FLAG_PADDED)) {
                            padlen = inbound_frame_compute_pad(iframe);
                            if (padlen < 0) {
                                busy = 1;
                                rv = http2_session_terminate_session_with_reason(
                                    session, http2_PROTOCOL_ERROR, "HEADERS: invalid padding");
                                if (http2_is_fatal(rv)) {
                                    return rv;
                                }
                                iframe.state = http2_IB_IGN_PAYLOAD;
                                break;
                            }
                            iframe.frame.headers.padlen = padlen;
                            
                            pri_fieldlen = http2_frame_priority_len(iframe.frame.hd.flags);
                            
                            if (pri_fieldlen > 0) {
                                if (iframe.payloadleft < pri_fieldlen) {
                                    busy = 1;
                                    iframe.state = http2_IB_FRAME_SIZE_ERROR;
                                    break;
                                }
                                iframe.state = http2_IB_READ_NBYTE;
                                inbound_frame_set_mark(iframe, pri_fieldlen);
                                break;
                            } else {
                                /* Truncate buffers used for padding spec */
                                inbound_frame_set_mark(iframe, 0);
                            }
                        }
                        
                        rv = session_process_headers_frame(session);
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                        
                        busy = 1;
                        
                        if (rv == ErrorCode.IGN_HEADER_BLOCK) {
                            iframe.state = http2_IB_IGN_HEADER_BLOCK;
                            break;
                        }
                        
                        iframe.state = http2_IB_READ_HEADER_BLOCK;
                        
                        break;
                    case http2_PRIORITY:
                        rv = session_process_priority_frame(session);
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                        
                        session_inbound_frame_reset(session);
                        
                        break;
                    case http2_RST_STREAM:
                        rv = session_process_rst_stream_frame(session);
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                        
                        session_inbound_frame_reset(session);
                        
                        break;
                    case http2_PUSH_PROMISE:
                        if (iframe.padlen == 0 &&
                            (iframe.frame.hd.flags & http2_FLAG_PADDED)) {
                            padlen = inbound_frame_compute_pad(iframe);
                            if (padlen < 0) {
                                busy = 1;
                                rv = http2_session_terminate_session_with_reason(
                                    session, http2_PROTOCOL_ERROR,
                                    "PUSH_PROMISE: invalid padding");
                                if (http2_is_fatal(rv)) {
                                    return rv;
                                }
                                iframe.state = http2_IB_IGN_PAYLOAD;
                                break;
                            }
                            
                            iframe.frame.push_promise.padlen = padlen;
                            
                            if (iframe.payloadleft < 4) {
                                busy = 1;
                                iframe.state = http2_IB_FRAME_SIZE_ERROR;
                                break;
                            }
                            
                            iframe.state = http2_IB_READ_NBYTE;
                            
                            inbound_frame_set_mark(iframe, 4);
                            
                            break;
                        }
                        
                        rv = session_process_push_promise_frame(session);
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                        
                        busy = 1;
                        
                        if (rv == ErrorCode.IGN_HEADER_BLOCK) {
                            iframe.state = http2_IB_IGN_HEADER_BLOCK;
                            break;
                        }
                        
                        iframe.state = http2_IB_READ_HEADER_BLOCK;
                        
                        break;
                    case http2_PING:
                        rv = session_process_ping_frame(session);
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                        
                        session_inbound_frame_reset(session);
                        
                        break;
                    case http2_GOAWAY: {
                        size_t debuglen;
                        
                        /* 8 is Last-stream-ID + Error Code */
                        debuglen = iframe.frame.hd.length - 8;
                        
                        if (debuglen > 0) {
                            iframe.raw_lbuf = http2_mem_malloc(mem, debuglen);
                            
                            if (iframe.raw_lbuf == NULL) {
                                return ErrorCode.NOMEM;
                            }
                            
                            http2_buf_wrap_init(&iframe.lbuf, iframe.raw_lbuf, debuglen);
                        }
                        
                        busy = 1;
                        
                        iframe.state = http2_IB_READ_GOAWAY_DEBUG;
                        
                        break;
                    }
                    case http2_WINDOW_UPDATE:
                        rv = session_process_window_update_frame(session);
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                        
                        session_inbound_frame_reset(session);
                        
                        break;
                    default:
                        /* This is unknown frame */
                        session_inbound_frame_reset(session);
                        
                        break;
                }
                break;
            case http2_IB_READ_HEADER_BLOCK:
            case http2_IB_IGN_HEADER_BLOCK: {
                size_t data_readlen;
#ifdef DEBUGBUILD
                if (iframe.state == http2_IB_READ_HEADER_BLOCK) {
                    fprintf(stderr, "recv: [IB_READ_HEADER_BLOCK]\n");
                } else {
                    fprintf(stderr, "recv: [IB_IGN_HEADER_BLOCK]\n");
                }
#endif /* DEBUGBUILD */
                
                readlen = inbound_frame_payload_readlen(iframe, input, last);
                
                DEBUGF(fprintf(stderr, "recv: readlen=%zu, payloadleft=%zu\n", readlen,
                        iframe.payloadleft - readlen));
                
                data_readlen = inbound_frame_effective_readlen(
                    iframe, iframe.payloadleft - readlen, readlen);
                if (data_readlen >= 0) {
                    size_t trail_padlen;
                    size_t hd_proclen = 0;
                    trail_padlen =
                        http2_frame_trail_padlen(&iframe.frame, iframe.padlen);
                    DEBUGF(fprintf(stderr, "recv: block final=%d\n",
                            (iframe.frame.hd.flags & http2_FLAG_END_HEADERS) &&
                            iframe.payloadleft - data_readlen == trail_padlen));
                    
                    rv = inflate_header_block(
                        session, &iframe.frame, &hd_proclen, (ubyte *)input, data_readlen,
                        (iframe.frame.hd.flags & http2_FLAG_END_HEADERS) &&
                        iframe.payloadleft - data_readlen == trail_padlen,
                        iframe.state == http2_IB_READ_HEADER_BLOCK);
                    
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                    
                    if (rv == ErrorCode.PAUSE) {
                        input += hd_proclen;
                        iframe.payloadleft -= hd_proclen;
                        
                        return in - first;
                    }
                    
                    if (rv == ErrorCode.TEMPORAL_CALLBACK_FAILURE) {
                        /* The application says no more headers. We decompress the
             rest of the header block but not invoke on_header_callback
             and on_frame_recv_callback. */
                        input += hd_proclen;
                        iframe.payloadleft -= hd_proclen;
                        
                        rv = http2_session_add_rst_stream(
                            session, iframe.frame.hd.stream_id, http2_INTERNAL_ERROR);
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                        busy = 1;
                        iframe.state = http2_IB_IGN_HEADER_BLOCK;
                        break;
                    }
                    
                    input += readlen;
                    iframe.payloadleft -= readlen;
                    
                    if (rv == ErrorCode.HEADER_COMP) {
                        /* GOAWAY is already issued */
                        if (iframe.payloadleft == 0) {
                            session_inbound_frame_reset(session);
                        } else {
                            busy = 1;
                            iframe.state = http2_IB_IGN_PAYLOAD;
                        }
                        break;
                    }
                } else {
                    input += readlen;
                    iframe.payloadleft -= readlen;
                }
                
                if (iframe.payloadleft) {
                    break;
                }
                
                if ((iframe.frame.hd.flags & http2_FLAG_END_HEADERS) == 0) {
                    
                    inbound_frame_set_mark(iframe, http2_FRAME_HDLEN);
                    
                    iframe.padlen = 0;
                    
                    if (iframe.state == http2_IB_READ_HEADER_BLOCK) {
                        iframe.state = http2_IB_EXPECT_CONTINUATION;
                    } else {
                        iframe.state = http2_IB_IGN_CONTINUATION;
                    }
                } else {
                    if (iframe.state == http2_IB_READ_HEADER_BLOCK) {
                        rv = session_after_header_block_received(session);
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                    }
                    session_inbound_frame_reset(session);
                }
                break;
            }
            case http2_IB_IGN_PAYLOAD:
                DEBUGF(fprintf(stderr, "recv: [IB_IGN_PAYLOAD]\n"));
                
                readlen = inbound_frame_payload_readlen(iframe, input, last);
                iframe.payloadleft -= readlen;
                input += readlen;
                
                DEBUGF(fprintf(stderr, "recv: readlen=%zu, payloadleft=%zu\n", readlen,
                        iframe.payloadleft));
                
                if (iframe.payloadleft) {
                    break;
                }
                
                switch (iframe.frame.hd.type) {
                    case http2_HEADERS:
                    case http2_PUSH_PROMISE:
                    case http2_CONTINUATION:
                        /* Mark inflater bad so that we won't perform further decoding */
                        session.hd_inflater.ctx.bad = 1;
                        break;
                    default:
                        break;
                }
                
                session_inbound_frame_reset(session);
                
                break;
            case http2_IB_FRAME_SIZE_ERROR:
                DEBUGF(fprintf(stderr, "recv: [IB_FRAME_SIZE_ERROR]\n"));
                
                rv = session_handle_frame_size_error(session, &iframe.frame);
                if (http2_is_fatal(rv)) {
                    return rv;
                }
                
                busy = 1;
                
                iframe.state = http2_IB_IGN_PAYLOAD;
                
                break;
            case http2_IB_READ_SETTINGS:
                DEBUGF(fprintf(stderr, "recv: [IB_READ_SETTINGS]\n"));
                
                readlen = inbound_frame_buf_read(iframe, input, last);
                iframe.payloadleft -= readlen;
                input += readlen;
                
                DEBUGF(fprintf(stderr, "recv: readlen=%zu, payloadleft=%zu\n", readlen,
                        iframe.payloadleft));
                
                if (http2_buf_mark_avail(&iframe.sbuf)) {
                    break;
                }
                
                if (readlen > 0) {
                    inbound_frame_set_settings_entry(iframe);
                }
                if (iframe.payloadleft) {
                    inbound_frame_set_mark(iframe, http2_FRAME_SETTINGS_ENTRY_LENGTH);
                    break;
                }
                
                rv = session_process_settings_frame(session);
                
                if (http2_is_fatal(rv)) {
                    return rv;
                }
                
                session_inbound_frame_reset(session);
                
                break;
            case http2_IB_READ_GOAWAY_DEBUG:
                DEBUGF(fprintf(stderr, "recv: [IB_READ_GOAWAY_DEBUG]\n"));
                
                readlen = inbound_frame_payload_readlen(iframe, input, last);
                
                iframe.lbuf.last = http2_cpymem(iframe.lbuf.last, input, readlen);
                
                iframe.payloadleft -= readlen;
                input += readlen;
                
                DEBUGF(fprintf(stderr, "recv: readlen=%zu, payloadleft=%zu\n", readlen,
                        iframe.payloadleft));
                
                if (iframe.payloadleft) {
                    assert(http2_buf_avail(&iframe.lbuf) > 0);
                    
                    break;
                }
                
                rv = session_process_goaway_frame(session);
                
                if (http2_is_fatal(rv)) {
                    return rv;
                }
                
                session_inbound_frame_reset(session);
                
                break;
            case http2_IB_EXPECT_CONTINUATION:
            case http2_IB_IGN_CONTINUATION:
#ifdef DEBUGBUILD
                if (iframe.state == http2_IB_EXPECT_CONTINUATION) {
                    fprintf(stderr, "recv: [IB_EXPECT_CONTINUATION]\n");
                } else {
                    fprintf(stderr, "recv: [IB_IGN_CONTINUATION]\n");
                }
#endif /* DEBUGBUILD */
                
                readlen = inbound_frame_buf_read(iframe, input, last);
                input += readlen;
                
                if (http2_buf_mark_avail(&iframe.sbuf)) {
                    return in - first;
                }
                
                http2_frame_unpack_frame_hd(&cont_hd, iframe.sbuf.pos);
                iframe.payloadleft = cont_hd.length;
                
                DEBUGF(fprintf(stderr, "recv: payloadlen=%zu, type=%u, flags=0x%02x, "
                        "stream_id=%d\n",
                        cont_hd.length, cont_hd.type, cont_hd.flags,
                        cont_hd.stream_id));
                
                if (cont_hd.type != http2_CONTINUATION ||
                    cont_hd.stream_id != iframe.frame.hd.stream_id) {
                    DEBUGF(fprintf(stderr, "recv: expected stream_id=%d, type=%d, but "
                            "got stream_id=%d, type=%d\n",
                            iframe.frame.hd.stream_id, http2_CONTINUATION,
                            cont_hd.stream_id, cont_hd.type));
                    rv = http2_session_terminate_session_with_reason(
                        session, http2_PROTOCOL_ERROR,
                        "unexpected non-CONTINUATION frame or stream_id is invalid");
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                    
                    busy = 1;
                    
                    iframe.state = http2_IB_IGN_PAYLOAD;
                    
                    break;
                }
                
                /* CONTINUATION won't bear http2_PADDED flag */
                
                iframe.frame.hd.flags |= cont_hd.flags & http2_FLAG_END_HEADERS;
                iframe.frame.hd.length += cont_hd.length;
                
                busy = 1;
                
                if (iframe.state == http2_IB_EXPECT_CONTINUATION) {
                    iframe.state = http2_IB_READ_HEADER_BLOCK;
                    
                    rv = session_call_on_begin_frame(session, &cont_hd);
                    
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                } else {
                    iframe.state = http2_IB_IGN_HEADER_BLOCK;
                }
                
                break;
            case http2_IB_READ_PAD_DATA:
                DEBUGF(fprintf(stderr, "recv: [IB_READ_PAD_DATA]\n"));
                
                readlen = inbound_frame_buf_read(iframe, input, last);
                input += readlen;
                iframe.payloadleft -= readlen;
                
                DEBUGF(fprintf(stderr, "recv: readlen=%zu, payloadleft=%zu, left=%zu\n",
                        readlen, iframe.payloadleft,
                        http2_buf_mark_avail(&iframe.sbuf)));
                
                if (http2_buf_mark_avail(&iframe.sbuf)) {
                    return in - first;
                }
                
                /* Pad Length field is subject to flow control */
                rv = session_update_recv_connection_window_size(session, readlen);
                if (http2_is_fatal(rv)) {
                    return rv;
                }
                
                /* Pad Length field is consumed immediately */
                rv =
                    http2_session_consume(session, iframe.frame.hd.stream_id, readlen);
                
                if (http2_is_fatal(rv)) {
                    return rv;
                }
                
                stream = http2_session_get_stream(session, iframe.frame.hd.stream_id);
                if (stream) {
                    rv = session_update_recv_stream_window_size(
                        session, stream, readlen,
                        iframe.payloadleft ||
                        (iframe.frame.hd.flags & http2_FLAG_END_STREAM) == 0);
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                }
                
                busy = 1;
                
                padlen = inbound_frame_compute_pad(iframe);
                if (padlen < 0) {
                    rv = http2_session_terminate_session_with_reason(
                        session, http2_PROTOCOL_ERROR, "DATA: invalid padding");
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                    iframe.state = http2_IB_IGN_DATA;
                    break;
                }
                
                iframe.frame.data.padlen = padlen;
                
                iframe.state = http2_IB_READ_DATA;
                
                break;
            case http2_IB_READ_DATA:
                DEBUGF(fprintf(stderr, "recv: [IB_READ_DATA]\n"));
                
                readlen = inbound_frame_payload_readlen(iframe, input, last);
                iframe.payloadleft -= readlen;
                input += readlen;
                
                DEBUGF(fprintf(stderr, "recv: readlen=%zu, payloadleft=%zu\n", readlen,
                        iframe.payloadleft));
                
                if (readlen > 0) {
                    size_t data_readlen;
                    
                    rv = session_update_recv_connection_window_size(session, readlen);
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                    
                    stream =
                        http2_session_get_stream(session, iframe.frame.hd.stream_id);
                    if (stream) {
                        rv = session_update_recv_stream_window_size(
                            session, stream, readlen,
                            iframe.payloadleft ||
                            (iframe.frame.hd.flags & http2_FLAG_END_STREAM) == 0);
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                    }
                    
                    data_readlen = inbound_frame_effective_readlen(
                        iframe, iframe.payloadleft, readlen);
                    
                    padlen = readlen - data_readlen;
                    
                    if (padlen > 0) {
                        /* Padding is considered as "consumed" immediately */
                        rv = http2_session_consume(session, iframe.frame.hd.stream_id,
                            padlen);
                        
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                    }
                    
                    DEBUGF(fprintf(stderr, "recv: data_readlen=%zd\n", data_readlen));
                    
                    if (stream && data_readlen > 0) {
                        if (session_enforce_http_messaging(session)) {
                            if (http2_http_on_data_chunk(stream, data_readlen) != 0) {
                                rv = http2_session_add_rst_stream(
                                    session, iframe.frame.hd.stream_id, http2_PROTOCOL_ERROR);
                                if (http2_is_fatal(rv)) {
                                    return rv;
                                }
                                busy = 1;
                                iframe.state = http2_IB_IGN_DATA;
                                break;
                            }
                        }
                        if (session.callbacks.on_data_chunk_recv_callback) {
                            rv = session.callbacks.on_data_chunk_recv_callback(
                                session, iframe.frame.hd.flags, iframe.frame.hd.stream_id,
                                in - readlen, data_readlen, session.user_data);
                            if (rv == ErrorCode.PAUSE) {
                                return in - first;
                            }
                            
                            if (http2_is_fatal(rv)) {
                                return ErrorCode.CALLBACK_FAILURE;
                            }
                        }
                    }
                }
                
                if (iframe.payloadleft) {
                    break;
                }
                
                rv = session_process_data_frame(session);
                if (http2_is_fatal(rv)) {
                    return rv;
                }
                
                session_inbound_frame_reset(session);
                
                break;
            case http2_IB_IGN_DATA:
                DEBUGF(fprintf(stderr, "recv: [IB_IGN_DATA]\n"));
                
                readlen = inbound_frame_payload_readlen(iframe, input, last);
                iframe.payloadleft -= readlen;
                input += readlen;
                
                DEBUGF(fprintf(stderr, "recv: readlen=%zu, payloadleft=%zu\n", readlen,
                        iframe.payloadleft));
                
                if (readlen > 0) {
                    /* Update connection-level flow control window for ignored
           DATA frame too */
                    rv = session_update_recv_connection_window_size(session, readlen);
                    if (http2_is_fatal(rv)) {
                        return rv;
                    }
                    
                    if (session.opt_flags & http2_OPTMASK_NO_AUTO_WINDOW_UPDATE) {
                        
                        /* Ignored DATA is considered as "consumed" immediately. */
                        rv = session_update_connection_consumed_size(session, readlen);
                        
                        if (http2_is_fatal(rv)) {
                            return rv;
                        }
                    }
                }
                
                if (iframe.payloadleft) {
                    break;
                }
                
                session_inbound_frame_reset(session);
                
                break;
            case http2_IB_IGN_ALL:
                return inlen;
        }
        
        if (!busy && in == last) {
            break;
        }
        
        busy = 0;
    }
    
    assert(in == last);
    
    return in - first;
}

int http2_session_recv(http2_session *session) {
    ubyte buf[http2_INBOUND_BUFFER_LENGTH];
    while (1) {
        size_t readlen;
        readlen = session_recv(session, buf, sizeof(buf));
        if (readlen > 0) {
            size_t proclen = http2_session_mem_recv(session, buf, readlen);
            if (proclen < 0) {
                return (int)proclen;
            }
            assert(proclen == readlen);
        } else if (readlen == 0 || readlen == ErrorCode.WOULDBLOCK) {
            return 0;
        } else if (readlen == ErrorCode.EOF) {
            return ErrorCode.EOF;
        } else if (readlen < 0) {
            return ErrorCode.CALLBACK_FAILURE;
        }
    }
}

/*
 * Returns the number of active streams, which includes streams in
 * reserved state.
 */
static size_t session_get_num_active_streams(http2_session *session) {
    return http2_map_size(&session.streams) - session.num_closed_streams;
}

int http2_session_want_read(http2_session *session) {
    size_t num_active_streams;
    
    /* If this flag is set, we don't want to read. The application
     should drop the connection. */
    if (session.goaway_flags & http2_GOAWAY_TERM_SENT) {
        return 0;
    }
    
    num_active_streams = session_get_num_active_streams(session);
    
    /* Unless termination GOAWAY is sent or received, we always want to
     read incoming frames. */
    
    if (num_active_streams > 0) {
        return 1;
    }
    
    /* If there is no active streams and GOAWAY has been sent or
     received, we are done with this session. */
    return (session.goaway_flags &
        (http2_GOAWAY_SENT | http2_GOAWAY_RECV)) == 0;
}

int http2_session_want_write(http2_session *session) {
    size_t num_active_streams;
    
    /* If these flag is set, we don't want to write any data. The
     application should drop the connection. */
    if (session.goaway_flags & http2_GOAWAY_TERM_SENT) {
        return 0;
    }
    
    num_active_streams = session_get_num_active_streams(session);
    
    /*
   * Unless termination GOAWAY is sent or received, we want to write
   * frames if there is pending ones. If pending frame is request/push
   * response HEADERS and concurrent stream limit is reached, we don't
   * want to write them.
   */
    
    if (session.aob.item == NULL && http2_pq_empty(&session.ob_pq) &&
        (http2_pq_empty(&session.ob_da_pq) ||
            session.remote_window_size == 0) &&
        (http2_pq_empty(&session.ob_ss_pq) ||
            session_is_outgoing_concurrent_streams_max(session))) {
        return 0;
    }
    
    if (num_active_streams > 0) {
        return 1;
    }
    
    /* If there is no active streams and GOAWAY has been sent or
     received, we are done with this session. */
    return (session.goaway_flags &
        (http2_GOAWAY_SENT | http2_GOAWAY_RECV)) == 0;
}

int http2_session_add_ping(http2_session *session, ubyte flags,
    const ubyte *opaque_data) {
    int rv;
    http2_outbound_item *item;
    http2_frame *frame;
    http2_mem *mem;
    
    mem = &session.mem;
    item = http2_mem_malloc(mem, sizeof(http2_outbound_item));
    if (item == NULL) {
        return ErrorCode.NOMEM;
    }
    
    http2_session_outbound_item_init(session, item);
    
    frame = &item.frame;
    
    http2_frame_ping_init(&frame.ping, flags, opaque_data);
    
    rv = http2_session_add_item(session, item);
    
    if (rv != 0) {
        http2_frame_ping_free(&frame.ping);
        http2_mem_free(mem, item);
        return rv;
    }
    return 0;
}

int http2_session_add_goaway(http2_session *session, int last_stream_id,
    uint error_code, const ubyte *opaque_data,
    size_t opaque_data_len, ubyte aux_flags) {
    int rv;
    http2_outbound_item *item;
    http2_frame *frame;
    ubyte *opaque_data_copy = NULL;
    http2_goaway_aux_data *aux_data;
    http2_mem *mem;
    
    mem = &session.mem;
    
    if (http2_session_is_my_stream_id(session, last_stream_id)) {
        return ErrorCode.INVALID_ARGUMENT;
    }
    
    if (opaque_data_len) {
        if (opaque_data_len + 8 > http2_MAX_PAYLOADLEN) {
            return ErrorCode.INVALID_ARGUMENT;
        }
        opaque_data_copy = http2_mem_malloc(mem, opaque_data_len);
        if (opaque_data_copy == NULL) {
            return ErrorCode.NOMEM;
        }
        memcpy(opaque_data_copy, opaque_data, opaque_data_len);
    }
    
    item = http2_mem_malloc(mem, sizeof(http2_outbound_item));
    if (item == NULL) {
        http2_mem_free(mem, opaque_data_copy);
        return ErrorCode.NOMEM;
    }
    
    http2_session_outbound_item_init(session, item);
    
    frame = &item.frame;
    
    /* last_stream_id must not be increased from the value previously
     sent */
    last_stream_id = http2_min(last_stream_id, session.local_last_stream_id);
    
    http2_frame_goaway_init(&frame.goaway, last_stream_id, error_code,
        opaque_data_copy, opaque_data_len);
    
    aux_data = &item.aux_data.goaway;
    aux_data.flags = aux_flags;
    
    rv = http2_session_add_item(session, item);
    if (rv != 0) {
        http2_frame_goaway_free(&frame.goaway, mem);
        http2_mem_free(mem, item);
        return rv;
    }
    return 0;
}

int http2_session_add_window_update(http2_session *session, ubyte flags,
    int stream_id,
    int window_size_increment) {
    int rv;
    http2_outbound_item *item;
    http2_frame *frame;
    http2_mem *mem;
    
    mem = &session.mem;
    item = http2_mem_malloc(mem, sizeof(http2_outbound_item));
    if (item == NULL) {
        return ErrorCode.NOMEM;
    }
    
    http2_session_outbound_item_init(session, item);
    
    frame = &item.frame;
    
    http2_frame_window_update_init(&frame.window_update, flags, stream_id,
        window_size_increment);
    
    rv = http2_session_add_item(session, item);
    
    if (rv != 0) {
        http2_frame_window_update_free(&frame.window_update);
        http2_mem_free(mem, item);
        return rv;
    }
    return 0;
}

int http2_session_add_settings(http2_session *session, ubyte flags,
    const http2_settings_entry *iv, size_t niv) {
    http2_outbound_item *item;
    http2_frame *frame;
    http2_settings_entry *iv_copy;
    size_t i;
    int rv;
    http2_mem *mem;
    
    mem = &session.mem;
    
    if (flags & http2_FLAG_ACK) {
        if (niv != 0) {
            return ErrorCode.INVALID_ARGUMENT;
        }
    } else if (session.inflight_niv != -1) {
        return ErrorCode.TOO_MANY_INFLIGHT_SETTINGS;
    }
    
    if (!http2_iv_check(iv, niv)) {
        return ErrorCode.INVALID_ARGUMENT;
    }
    
    item = http2_mem_malloc(mem, sizeof(http2_outbound_item));
    if (item == NULL) {
        return ErrorCode.NOMEM;
    }
    
    if (niv > 0) {
        iv_copy = http2_frame_iv_copy(iv, niv, mem);
        if (iv_copy == NULL) {
            http2_mem_free(mem, item);
            return ErrorCode.NOMEM;
        }
    } else {
        iv_copy = NULL;
    }
    
    if ((flags & http2_FLAG_ACK) == 0) {
        if (niv > 0) {
            session.inflight_iv = http2_frame_iv_copy(iv, niv, mem);
            
            if (session.inflight_iv == NULL) {
                http2_mem_free(mem, iv_copy);
                http2_mem_free(mem, item);
                return ErrorCode.NOMEM;
            }
        } else {
            session.inflight_iv = NULL;
        }
        
        session.inflight_niv = niv;
    }
    
    http2_session_outbound_item_init(session, item);
    
    frame = &item.frame;
    
    http2_frame_settings_init(&frame.settings, flags, iv_copy, niv);
    rv = http2_session_add_item(session, item);
    if (rv != 0) {
        /* The only expected error is fatal one */
        assert(http2_is_fatal(rv));
        
        if ((flags & http2_FLAG_ACK) == 0) {
            http2_mem_free(mem, session.inflight_iv);
            session.inflight_iv = NULL;
            session.inflight_niv = -1;
        }
        
        http2_frame_settings_free(&frame.settings, mem);
        http2_mem_free(mem, item);
        
        return rv;
    }
    
    /* Extract http2_SETTINGS_MAX_CONCURRENT_STREAMS here and use
     it to refuse the incoming streams with RST_STREAM. */
    for (i = niv; i > 0; --i) {
        if (iv[i - 1].settings_id == http2_SETTINGS_MAX_CONCURRENT_STREAMS) {
            session.pending_local_max_concurrent_stream = iv[i - 1].value;
            break;
        }
    }
    
    return 0;
}

int http2_session_pack_data(http2_session *session, http2_bufs *bufs,
    size_t datamax, http2_frame *frame,
    http2_data_aux_data *aux_data) {
    int rv;
    uint data_flags;
    size_t payloadlen;
    size_t padded_payloadlen;
    http2_buf *buf;
    size_t max_payloadlen;
    
    assert(bufs.head == bufs.cur);
    
    buf = &bufs.cur.buf;
    
    if (session.callbacks.read_length_callback) {
        http2_stream *stream;
        
        stream = http2_session_get_stream(session, frame.hd.stream_id);
        if (!stream) {
            return ErrorCode.INVALID_ARGUMENT;
        }
        
        payloadlen = session.callbacks.read_length_callback(
            session, frame.hd.type, stream.stream_id, session.remote_window_size,
            stream.remote_window_size, session.remote_settings.max_frame_size,
            session.user_data);
        
        DEBUGF(fprintf(stderr, "send: read_length_callback=%zd\n", payloadlen));
        
        payloadlen = http2_session_enforce_flow_control_limits(session, stream,
            payloadlen);
        
        DEBUGF(fprintf(stderr,
                "send: read_length_callback after flow control=%zd\n",
                payloadlen));
        
        if (payloadlen <= 0) {
            return ErrorCode.CALLBACK_FAILURE;
        }
        
        if (payloadlen > http2_buf_avail(buf)) {
            /* Resize the current buffer(s).  The reason why we do +1 for
         buffer size is for possible padding field. */
            rv = http2_bufs_realloc(&session.aob.framebufs,
                http2_FRAME_HDLEN + 1 + payloadlen);
            
            if (rv != 0) {
                DEBUGF(fprintf(stderr, "send: realloc buffer failed rv=%d", rv));
                /* If reallocation failed, old buffers are still in tact.  So
           use safe limit. */
                payloadlen = datamax;
                
                DEBUGF(
                    fprintf(stderr, "send: use safe limit payloadlen=%zd", payloadlen));
            } else {
                assert(&session.aob.framebufs == bufs);
                
                buf = &bufs.cur.buf;
            }
        }
        datamax = (size_t)payloadlen;
    }
    
    /* Current max DATA length is less then buffer chunk size */
    assert(http2_buf_avail(buf) >= (size_t)datamax);
    
    data_flags = http2_DATA_FLAG_NONE;
    payloadlen = aux_data.data_prd.read_callback(
        session, frame.hd.stream_id, buf.pos, datamax, &data_flags,
        &aux_data.data_prd.source, session.user_data);
    
    if (payloadlen == ErrorCode.DEFERRED ||
        payloadlen == ErrorCode.TEMPORAL_CALLBACK_FAILURE) {
        DEBUGF(fprintf(stderr, "send: DATA postponed due to %s\n",
                http2_strerror((int)payloadlen)));
        
        return (int)payloadlen;
    }
    
    if (payloadlen < 0 || datamax < (size_t)payloadlen) {
        /* This is the error code when callback is failed. */
        return ErrorCode.CALLBACK_FAILURE;
    }
    
    buf.last = buf.pos + payloadlen;
    buf.pos -= http2_FRAME_HDLEN;
    
    /* Clear flags, because this may contain previous flags of previous
     DATA */
    frame.hd.flags = http2_FLAG_NONE;
    
    if (data_flags & http2_DATA_FLAG_EOF) {
        aux_data.eof = 1;
        if (aux_data.flags & http2_FLAG_END_STREAM) {
            frame.hd.flags |= http2_FLAG_END_STREAM;
        }
    }
    
    frame.hd.length = payloadlen;
    frame.data.padlen = 0;
    
    max_payloadlen = http2_min(datamax, frame.hd.length + http2_MAX_PADLEN);
    
    padded_payloadlen =
        session_call_select_padding(session, frame, max_payloadlen);
    
    if (http2_is_fatal((int)padded_payloadlen)) {
        return (int)padded_payloadlen;
    }
    
    frame.data.padlen = padded_payloadlen - payloadlen;
    
    http2_frame_pack_frame_hd(buf.pos, &frame.hd);
    
    rv = http2_frame_add_pad(bufs, &frame.hd, frame.data.padlen);
    if (rv != 0) {
        return rv;
    }
    
    return 0;
}

void *http2_session_get_stream_user_data(http2_session *session,
    int stream_id) {
    http2_stream *stream;
    stream = http2_session_get_stream(session, stream_id);
    if (stream) {
        return stream.stream_user_data;
    } else {
        return NULL;
    }
}

int http2_session_set_stream_user_data(http2_session *session,
    int stream_id,
    void *stream_user_data) {
    http2_stream *stream;
    stream = http2_session_get_stream(session, stream_id);
    if (!stream) {
        return ErrorCode.INVALID_ARGUMENT;
    }
    stream.stream_user_data = stream_user_data;
    return 0;
}

int http2_session_resume_data(http2_session *session, int stream_id) {
    int rv;
    http2_stream *stream;
    stream = http2_session_get_stream(session, stream_id);
    if (stream == NULL || !http2_stream_check_deferred_item(stream)) {
        return ErrorCode.INVALID_ARGUMENT;
    }
    
    rv = http2_stream_resume_deferred_item(
        stream, http2_STREAM_FLAG_DEFERRED_USER, session);
    
    if (http2_is_fatal(rv)) {
        return rv;
    }
    
    return rv;
}

size_t http2_session_get_outbound_queue_size(http2_session *session) {
    return http2_pq_size(&session.ob_pq) +
        http2_pq_size(&session.ob_ss_pq) +
            http2_pq_size(&session.ob_da_pq);
}

int
    http2_session_get_stream_effective_recv_data_length(http2_session *session,
int stream_id) {
    http2_stream *stream;
    stream = http2_session_get_stream(session, stream_id);
    if (stream == NULL) {
        return -1;
    }
    return stream.recv_window_size < 0 ? 0 : stream.recv_window_size;
}

int
    http2_session_get_stream_effective_local_window_size(http2_session *session,
int stream_id) {
    http2_stream *stream;
    stream = http2_session_get_stream(session, stream_id);
    if (stream == NULL) {
        return -1;
    }
    return stream.local_window_size;
}

int
http2_session_get_effective_recv_data_length(http2_session *session) {
    return session.recv_window_size < 0 ? 0 : session.recv_window_size;
}

int
http2_session_get_effective_local_window_size(http2_session *session) {
    return session.local_window_size;
}

int http2_session_get_stream_remote_window_size(http2_session *session,
    int stream_id) {
    http2_stream *stream;
    
    stream = http2_session_get_stream(session, stream_id);
    if (stream == NULL) {
        return -1;
    }
    
    /* stream.remote_window_size can be negative when
     SETTINGS_INITIAL_WINDOW_SIZE is changed. */
    return http2_max(0, stream.remote_window_size);
}

int http2_session_get_remote_window_size(http2_session *session) {
    return session.remote_window_size;
}

uint http2_session_get_remote_settings(http2_session *session,
    http2_settings_id id) {
    switch (id) {
        case http2_SETTINGS_HEADER_TABLE_SIZE:
            return session.remote_settings.header_table_size;
        case http2_SETTINGS_ENABLE_PUSH:
            return session.remote_settings.enable_push;
        case http2_SETTINGS_MAX_CONCURRENT_STREAMS:
            return session.remote_settings.max_concurrent_streams;
        case http2_SETTINGS_INITIAL_WINDOW_SIZE:
            return session.remote_settings.initial_window_size;
        case http2_SETTINGS_MAX_FRAME_SIZE:
            return session.remote_settings.max_frame_size;
        case http2_SETTINGS_MAX_HEADER_LIST_SIZE:
            return session.remote_settings.max_header_list_size;
    }
    
    assert(0);
}

int http2_session_upgrade(http2_session *session,
    const ubyte *settings_payload,
    size_t settings_payloadlen,
    void *stream_user_data) {
    http2_stream *stream;
    http2_frame frame;
    http2_settings_entry *iv;
    size_t niv;
    int rv;
    http2_priority_spec pri_spec;
    http2_mem *mem;
    
    mem = &session.mem;
    
    if ((!session.server && session.next_stream_id != 1) ||
        (session.server && session.last_recv_stream_id >= 1)) {
        return ErrorCode.PROTO;
    }
    if (settings_payloadlen % http2_FRAME_SETTINGS_ENTRY_LENGTH) {
        return ErrorCode.INVALID_ARGUMENT;
    }
    rv = http2_frame_unpack_settings_payload2(&iv, &niv, settings_payload,
        settings_payloadlen, mem);
    if (rv != 0) {
        return rv;
    }
    
    if (session.server) {
        http2_frame_hd_init(&frame.hd, settings_payloadlen, http2_SETTINGS,
            http2_FLAG_NONE, 0);
        frame.settings.iv = iv;
        frame.settings.niv = niv;
        rv = http2_session_on_settings_received(session, &frame, 1 /* No ACK */);
    } else {
        rv = http2_submit_settings(session, http2_FLAG_NONE, iv, niv);
    }
    http2_mem_free(mem, iv);
    if (rv != 0) {
        return rv;
    }
    
    http2_priority_spec_default_init(&pri_spec);
    
    stream = http2_session_open_stream(
        session, 1, http2_STREAM_FLAG_NONE, &pri_spec, http2_STREAM_OPENING,
        session.server ? NULL : stream_user_data);
    if (stream == NULL) {
        return ErrorCode.NOMEM;
    }
    if (session.server) {
        http2_stream_shutdown(stream, http2_SHUT_RD);
        session.last_recv_stream_id = 1;
        session.last_proc_stream_id = 1;
    } else {
        http2_stream_shutdown(stream, http2_SHUT_WR);
        session.next_stream_id += 2;
    }
    return 0;
}

int http2_session_get_stream_local_close(http2_session *session,
    int stream_id) {
    http2_stream *stream;
    
    stream = http2_session_get_stream(session, stream_id);
    
    if (!stream) {
        return -1;
    }
    
    return (stream.shut_flags & http2_SHUT_WR) != 0;
}

int http2_session_get_stream_remote_close(http2_session *session,
    int stream_id) {
    http2_stream *stream;
    
    stream = http2_session_get_stream(session, stream_id);
    
    if (!stream) {
        return -1;
    }
    
    return (stream.shut_flags & http2_SHUT_RD) != 0;
}

int http2_session_consume(http2_session *session, int stream_id,
    size_t size) {
    int rv;
    http2_stream *stream;
    
    if (stream_id == 0) {
        return ErrorCode.INVALID_ARGUMENT;
    }
    
    if (!(session.opt_flags & http2_OPTMASK_NO_AUTO_WINDOW_UPDATE)) {
        return ErrorCode.INVALID_STATE;
    }
    
    rv = session_update_connection_consumed_size(session, size);
    
    if (http2_is_fatal(rv)) {
        return rv;
    }
    
    stream = http2_session_get_stream(session, stream_id);
    
    if (stream) {
        rv = session_update_stream_consumed_size(session, stream, size);
        
        if (http2_is_fatal(rv)) {
            return rv;
        }
    }
    
    return 0;
}

int http2_session_set_next_stream_id(http2_session *session,
    int next_stream_id) {
    if (next_stream_id < 0 ||
        session.next_stream_id > cast(uint)next_stream_id) {
        return ErrorCode.INVALID_ARGUMENT;
    }
    
    session.next_stream_id = next_stream_id;
    return 0;
}

uint http2_session_get_next_stream_id(http2_session *session) {
    return session.next_stream_id;
}

int http2_session_get_last_proc_stream_id(http2_session *session) {
    return session.last_proc_stream_id;
}
