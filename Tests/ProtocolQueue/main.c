#include "ventrilo3.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>

extern int v3_queue_event(v3_event *event);
extern v3_event *_v3_create_event(uint16_t type);

static void enqueue(uint16_t id) {
    v3_event *event = _v3_create_event(V3_EVENT_PING);
    event->ping = id;
    assert(v3_queue_event(event));
}

static void *produce(void *unused) {
    (void)unused;
    for (unsigned i = 0; i < 10000; i++) { enqueue((uint16_t)i); }
    return NULL;
}

int main(void) {
    assert(v3_get_event(V3_NONBLOCK) == NULL);
    for (unsigned i = 0; i < 10000; i++) { enqueue((uint16_t)i); }
    for (unsigned i = 0; i < 10000; i++) {
        v3_event *event = v3_get_event(V3_NONBLOCK);
        assert(event && event->ping == i);
        v3_free_event(event);
    }
    assert(v3_get_event(V3_NONBLOCK) == NULL);
    enqueue(1);
    enqueue(2);
    v3_clear_events();
    assert(v3_get_event(V3_NONBLOCK) == NULL);
    enqueue(3);
    v3_event *event = v3_get_event(V3_NONBLOCK);
    assert(event && event->ping == 3);
    v3_free_event(event);

    pthread_t producer;
    assert(pthread_create(&producer, NULL, produce, NULL) == 0);
    for (unsigned i = 0; i < 10000; i++) {
        event = v3_get_event(V3_BLOCK);
        assert(event && event->ping == i);
        v3_free_event(event);
    }
    assert(pthread_join(producer, NULL) == 0);
    assert(v3_get_event(V3_NONBLOCK) == NULL);
    puts("Protocol queue: 20,000 FIFO events, concurrent producer/consumer, clear and reuse passed");
    return 0;
}
