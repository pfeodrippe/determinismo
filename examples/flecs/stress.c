/* SPDX-License-Identifier: MIT */
/*
 * flecs-stress: Flecs (an in-memory entity component system) driven by long random operation
 * sequences and checked against a model of what it must hold, under determinismo.
 *
 * Each round makes a world with worker threads or none, systems that run on them and observers,
 * then applies random operations: entities created (alone, as children, as instances of
 * prefabs), deleted (their children with them, relationships to them removed), components set
 * and removed, tags, an exclusive relationship, reparenting, deferred batches, frames of the
 * systems. A model mirrors each one; after it, the entities it touched are checked against
 * Flecs (alive or not, components and values, tags, parent, relationship, prefab), and every so
 * often all of them, two queries (one cached) and children lists. Inside the systems, on the
 * worker threads: each entity is visited once a frame.
 *
 * The SDK goes further in: Flecs's OS hooks (mutexes, condition variables, threads, atomic
 * counters) yield the CPU when the platform says so (buggify), so the explorer varies the
 * interleavings exactly where Flecs synchronizes; Flecs's own checks (a sanitize build) report as
 * an assertion instead of a bare abort. Every choice comes from the SDK: a timeline replays, and
 * strategies steer the operations by name.
 *
 * Outside determinismo it runs as is (OS randomness, events on stderr): `flecs-stress [rounds]`.
 */
#define DETERMINISMO_IMPLEMENTATION
#include "determinismo.h"

#include "flecs.h"

#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    slots_max = 96,
    prefabs_max = 4,
    tags_max = 3,
    batch_max = 6,
    frames_max = 3,
    threads_max = 4,
    steps_min = 200,
    steps_max = 600,
    check_every = 25,
    details_max = 512,
};

typedef struct { float x, y; } Position;
typedef struct { float x, y; } Velocity;
typedef struct { int32_t value; } Health;
/* The model's slot of an entity (prefabs have none: instances copy everything else). */
typedef struct { int32_t index; } Slot;

ECS_COMPONENT_DECLARE(Position);
ECS_COMPONENT_DECLARE(Velocity);
ECS_COMPONENT_DECLARE(Health);
ECS_COMPONENT_DECLARE(Slot);

typedef struct {
    bool has_position, has_velocity, has_health;
    Position position;
    Velocity velocity;
    int32_t health;
    uint8_t tags;
} Data;

typedef struct {
    ecs_entity_t entity; /* 0: never used, or deleted (then `was` keeps it). */
    ecs_entity_t was;
    Data data;
    int16_t parent; /* Slots, or -1. */
    int16_t likes;
    int16_t prefab;
    bool doomed; /* Deleted earlier in the deferred batch under way (itself or a parent). */
    _Atomic uint32_t moved;   /* The frame the Move system last visited it. */
    _Atomic uint32_t decayed; /* The frame the Decay system last visited it. */
} Model;

typedef struct {
    ecs_entity_t entity;
    Data data;
} Prefab;

static ecs_world_t *world;
static Model model[slots_max];
static Prefab prefabs[prefabs_max];
static ecs_entity_t tags[tags_max];
static ecs_entity_t likes;
static ecs_query_t *query_moving; /* Position, Velocity: cached. */
static ecs_query_t *query_still;  /* Position, tag 1, not Velocity: uncached. */
static int threads;
static uint32_t frame;
static _Atomic uint32_t frame_stages; /* Bit per stage that ran a system this frame. */
static bool deferring;
/* Where operations write: the world, or during a batch its stage 0 (readonly mode, as systems
 * write: the commands merge at its end). */
static ecs_world_t *writer;
static char last_error[details_max];

/* Randomness for hot hooks (atomic counters): seeded from the platform each round, so it
 * replays; coarser points ask the platform each time (det_buggify), which strategies steer. */
static _Atomic uint64_t hook_random;

static uint64_t hook_next(void) {
    uint64_t value = atomic_load(&hook_random);
    uint64_t next;
    do {
        next = value ^ (value << 13);
        next ^= next >> 7;
        next ^= next << 17;
    } while (!atomic_compare_exchange_weak(&hook_random, &value, next));
    return next;
}

/* Flecs's OS hooks, around the defaults ---------------------------------------------------------- */

static ecs_os_api_t base;

static void hooked_mutex_lock(ecs_os_mutex_t mutex) {
    if (det_buggify("flecs.mutex_lock")) sched_yield();
    base.mutex_lock_(mutex);
}

static void hooked_mutex_unlock(ecs_os_mutex_t mutex) {
    base.mutex_unlock_(mutex);
    if (det_buggify("flecs.mutex_unlock")) sched_yield();
}

static void hooked_cond_wait(ecs_os_cond_t cond, ecs_os_mutex_t mutex) {
    base.cond_wait_(cond, mutex);
    if (det_buggify("flecs.cond_wakeup")) sched_yield();
}

static void hooked_cond_signal(ecs_os_cond_t cond) {
    if (det_buggify("flecs.cond_signal")) sched_yield();
    base.cond_signal_(cond);
}

static void hooked_cond_broadcast(ecs_os_cond_t cond) {
    if (det_buggify("flecs.cond_broadcast")) sched_yield();
    base.cond_broadcast_(cond);
}

static ecs_os_thread_t hooked_thread_new(ecs_os_thread_callback_t callback, void *arg) {
    ecs_os_thread_t thread = base.thread_new_(callback, arg);
    if (det_buggify("flecs.thread_new")) sched_yield();
    return thread;
}

static int32_t hooked_ainc(int32_t *count) {
    if (hook_next() % 64 == 0) sched_yield();
    return base.ainc_(count);
}

static int32_t hooked_adec(int32_t *count) {
    if (hook_next() % 64 == 0) sched_yield();
    return base.adec_(count);
}

static void hooked_log(int32_t level, const char *file, int32_t line, const char *message) {
    if (level <= -3) snprintf(last_error, sizeof last_error, "%s:%d: %s", file ? file : "?", line, message);
    base.log_(level, file, line, message);
}

static void hooked_abort(void) {
    char details[details_max + 32];
    char escaped[details_max];
    size_t used = 0;
    /* JSON: quotes and backslashes escaped, Flecs's terminal colors (ESC [ ... m) and other
     * control characters left out. */
    for (const char *c = last_error; *c && used + 2 < sizeof escaped; c++) {
        if (*c == 0x1b) {
            while (c[1] && c[1] != 'm') c++;
            if (c[1]) c++;
            continue;
        }
        if ((unsigned char)*c < 0x20) {
            escaped[used++] = ' ';
            continue;
        }
        if (*c == '"' || *c == '\\') escaped[used++] = '\\';
        escaped[used++] = *c;
    }
    escaped[used] = 0;
    snprintf(details, sizeof details, "{\"error\":\"%s\"}", escaped);
    DET_UNREACHABLE("Flecs's own checks never fail (it aborts on one)", details);
    base.abort_();
}

static void os_hooks(void) {
    ecs_os_set_api_defaults();
    base = ecs_os_api;
    ecs_os_api_t api = ecs_os_api;
    api.mutex_lock_ = hooked_mutex_lock;
    api.mutex_unlock_ = hooked_mutex_unlock;
    api.cond_wait_ = hooked_cond_wait;
    api.cond_signal_ = hooked_cond_signal;
    api.cond_broadcast_ = hooked_cond_broadcast;
    api.thread_new_ = hooked_thread_new;
    api.ainc_ = hooked_ainc;
    api.adec_ = hooked_adec;
    api.log_ = hooked_log;
    api.abort_ = hooked_abort;
    ecs_os_set_api(&api);
}

/* Systems and observers (Flecs calls them, on worker threads for the systems) ----------------- */

static void Move(ecs_iter_t *it) {
    Position *p = ecs_field(it, Position, 0);
    const Velocity *v = ecs_field(it, Velocity, 1);
    const Slot *s = ecs_field(it, Slot, 2);
    atomic_fetch_or(&frame_stages, 1u << (ecs_stage_get_id(it->stage) & 31));
    for (int i = 0; i < it->count; i++) {
        p[i].x += v[i].x;
        p[i].y += v[i].y;
        uint32_t before = atomic_exchange(&model[s[i].index].moved, frame);
        DET_ALWAYS(before != frame, "a multi-threaded system visits each entity once a frame", NULL);
    }
}

static void Decay(ecs_iter_t *it) {
    Health *h = ecs_field(it, Health, 0);
    const Slot *s = ecs_field(it, Slot, 2);
    atomic_fetch_or(&frame_stages, 1u << (ecs_stage_get_id(it->stage) & 31));
    for (int i = 0; i < it->count; i++) {
        uint32_t before = atomic_exchange(&model[s[i].index].decayed, frame);
        DET_ALWAYS(before != frame, "a multi-threaded system visits each entity once a frame", NULL);
        h[i].value -= 1;
        if (h[i].value > 0) continue;
        /* Queued in the system's stage (it->world is the world itself, since Flecs master's
         * 2c517a7: deleting there runs at once, in a table being iterated). */
        ecs_delete(it->stage, it->entities[i]);
        DET_SOMETIMES(ecs_stage_get_id(it->stage) > 0, "a system deletes an entity from a worker thread", NULL);
    }
}

static void PositionSet(ecs_iter_t *it) {
    const Position *p = ecs_field(it, Position, 0);
    for (int i = 0; i < it->count; i++) {
        DET_ALWAYS(ecs_is_alive(it->world, it->entities[i]), "an observer sees live entities", NULL);
        DET_ALWAYS(p != NULL, "an OnSet observer sees the value set", NULL);
    }
    DET_SOMETIMES(deferring, "an observer runs as a deferred batch merges", NULL);
}

static void HealthRemoved(ecs_iter_t *it) {
    for (int i = 0; i < it->count; i++) {
        DET_ALWAYS(ecs_is_alive(it->world, it->entities[i]), "an observer sees live entities", NULL);
    }
    DET_SOMETIMES(it->count > 0, "an OnRemove observer runs", NULL);
}

/* The model ------------------------------------------------------------------------------------ */

static bool alive(int slot) { return slot >= 0 && model[slot].entity != 0; }

static bool usable(int slot) { return alive(slot) && !model[slot].doomed; }

static int pick_alive(void) {
    int start = (int)det_random_below(slots_max);
    for (int i = 0; i < slots_max; i++) {
        int slot = (start + i) % slots_max;
        if (usable(slot)) return slot;
    }
    return -1;
}

static int pick_free(void) {
    int start = (int)det_random_below(slots_max);
    for (int i = 0; i < slots_max; i++) {
        int slot = (start + i) % slots_max;
        if (model[slot].entity == 0 && !model[slot].doomed) return slot;
    }
    return -1;
}

static bool descends_from(int slot, int ancestor) {
    for (int at = slot; at >= 0; at = model[at].parent) {
        if (at == ancestor) return true;
    }
    return false;
}

/* Deleting removes the children too, and the relationship pairs that point at it. */
static void model_delete(int slot) {
    for (int i = 0; i < slots_max; i++) {
        if (alive(i) && model[i].parent == slot) model_delete(i);
    }
    for (int i = 0; i < slots_max; i++) {
        if (alive(i) && model[i].likes == slot) model[i].likes = -1;
    }
    model[slot].was = model[slot].entity;
    model[slot].entity = 0;
}

/* In a deferred batch: a deletion takes effect at the merge; until then, it and its children
 * are not picked again (what Flecs does with commands on an entity deleted in the same batch is
 * its own business). */
static void model_doom(int slot) {
    model[slot].doomed = true;
    for (int i = 0; i < slots_max; i++) {
        if (alive(i) && model[i].parent == slot && !model[i].doomed) model_doom(i);
    }
}

/* Checks --------------------------------------------------------------------------------------- */

static void details_slot(char *out, size_t size, int slot, const char *what) {
    snprintf(out, size, "{\"slot\":%d,\"entity\":%llu,\"was\":%llu,\"what\":\"%s\",\"round_frame\":%u}",
             slot, (unsigned long long)model[slot].entity, (unsigned long long)model[slot].was, what, frame);
}

static bool same_position(const Position *a, Position b) { return a && a->x == b.x && a->y == b.y; }
static bool same_velocity(const Velocity *a, Velocity b) { return a && a->x == b.x && a->y == b.y; }

static void check_slot(int slot) {
    char details[details_max];
    const Model *m = &model[slot];
    if (!alive(slot)) {
        if (m->was == 0) return;
        details_slot(details, sizeof details, slot, "deleted");
        DET_ALWAYS(!ecs_is_alive(world, m->was), "a deleted entity is not alive", details);
        return;
    }
    ecs_entity_t e = m->entity;
    details_slot(details, sizeof details, slot, "alive");
    DET_ALWAYS(ecs_is_alive(world, e), "an entity the model holds is alive", details);
    if (!ecs_is_alive(world, e)) return;
    bool components = ecs_has(world, e, Position) == m->data.has_position &&
                      ecs_has(world, e, Velocity) == m->data.has_velocity &&
                      ecs_has(world, e, Health) == m->data.has_health;
    details_slot(details, sizeof details, slot, "components");
    DET_ALWAYS(components, "an entity has exactly the components the model says", details);
    bool values = true;
    if (m->data.has_position) values = values && same_position(ecs_get(world, e, Position), m->data.position);
    if (m->data.has_velocity) values = values && same_velocity(ecs_get(world, e, Velocity), m->data.velocity);
    if (m->data.has_health) {
        const Health *h = ecs_get(world, e, Health);
        values = values && h && h->value == m->data.health;
    }
    details_slot(details, sizeof details, slot, "values");
    DET_ALWAYS(values, "a component holds the value last written to it", details);
    bool tagged = true;
    for (int t = 0; t < tags_max; t++) tagged = tagged && ecs_has_id(world, e, tags[t]) == ((m->data.tags >> t) & 1);
    details_slot(details, sizeof details, slot, "tags");
    DET_ALWAYS(tagged, "an entity has exactly the tags the model says", details);
    ecs_entity_t parent = ecs_get_target(world, e, EcsChildOf, 0);
    details_slot(details, sizeof details, slot, "parent");
    DET_ALWAYS(parent == (m->parent >= 0 ? model[m->parent].entity : 0), "an entity's parent is the one the model says", details);
    ecs_entity_t target = ecs_get_target(world, e, likes, 0);
    details_slot(details, sizeof details, slot, "likes");
    DET_ALWAYS(target == (m->likes >= 0 ? model[m->likes].entity : 0),
               "an entity's relationship target is the one the model says", details);
    if (m->prefab >= 0) {
        details_slot(details, sizeof details, slot, "prefab");
        DET_ALWAYS(ecs_has_pair(world, e, EcsIsA, prefabs[m->prefab].entity), "an instance keeps its prefab", details);
    }
}

static int query_count(ecs_query_t *query, bool (*expected)(int slot), int *unexpected) {
    int count = 0;
    ecs_iter_t it = ecs_query_iter(world, query);
    while (ecs_query_next(&it)) {
        for (int i = 0; i < it.count; i++) {
            const Slot *s = ecs_get(world, it.entities[i], Slot);
            if (!s || s->index < 0 || s->index >= slots_max || model[s->index].entity != it.entities[i] ||
                !expected(s->index)) {
                *unexpected += 1;
            }
            count += 1;
        }
    }
    return count;
}

static bool moving(int slot) { return model[slot].data.has_position && model[slot].data.has_velocity; }

static bool still(int slot) {
    const Data *d = &model[slot].data;
    return d->has_position && !d->has_velocity && ((d->tags >> 1) & 1);
}

static void check_all(void) {
    for (int slot = 0; slot < slots_max; slot++) check_slot(slot);
    int want_moving = 0, want_still = 0;
    for (int slot = 0; slot < slots_max; slot++) {
        if (!alive(slot)) continue;
        want_moving += moving(slot);
        want_still += still(slot);
    }
    int unexpected = 0;
    int got_moving = query_count(query_moving, moving, &unexpected);
    int got_still = query_count(query_still, still, &unexpected);
    char details[details_max];
    snprintf(details, sizeof details,
             "{\"moving\":[%d,%d],\"still\":[%d,%d],\"unexpected\":%d,\"round_frame\":%u}",
             got_moving, want_moving, got_still, want_still, unexpected, frame);
    DET_ALWAYS(got_moving == want_moving && got_still == want_still && unexpected == 0,
               "a query matches exactly the entities the model says", details);
    int parent = pick_alive();
    if (parent < 0) return;
    int want_children = 0, got_children = 0;
    for (int slot = 0; slot < slots_max; slot++) want_children += alive(slot) && model[slot].parent == parent;
    ecs_iter_t it = ecs_children(world, model[parent].entity);
    while (ecs_children_next(&it)) got_children += it.count;
    snprintf(details, sizeof details, "{\"slot\":%d,\"children\":[%d,%d]}", parent, got_children, want_children);
    DET_ALWAYS(got_children == want_children, "a parent's children are the ones the model says", details);
}

/* Operations ----------------------------------------------------------------------------------- */

static Position random_position(void) {
    return (Position){(float)det_random_below(200) - 100, (float)det_random_below(200) - 100};
}

static Velocity random_velocity(void) {
    return (Velocity){(float)det_random_below(9) - 4, (float)det_random_below(9) - 4};
}

static void entity_ready(int slot, ecs_entity_t e) {
    model[slot].entity = e;
    model[slot].was = 0;
    model[slot].parent = -1;
    model[slot].likes = -1;
    model[slot].prefab = -1;
    model[slot].doomed = false;
    memset(&model[slot].data, 0, sizeof model[slot].data);
    ecs_set(writer, e, Slot, {slot});
}

/* One operation: the slot it touched (to check), or -1. */
static int operate(void) {
    static const char *const names[] = {
        "create", "create child", "instantiate", "delete", "set position", "set velocity",
        "set health", "remove component", "toggle tag", "relationship", "reparent",
    };
    size_t op = det_decide("flecs.operation", names, deferring ? 10 : 11); /* No reparenting deferred. */
    int slot = pick_alive();
    switch (op) {
    case 0:
    case 1:
    case 2: {
        int free = pick_free();
        if (free < 0) return -1;
        int parent = op == 1 ? slot : -1;
        if (op == 1 && parent < 0) return -1;
        int prefab = op == 2 ? (int)det_random_below(prefabs_max) : -1;
        ecs_entity_t e = prefab >= 0 ? ecs_new_w_pair(writer, EcsIsA, prefabs[prefab].entity) : ecs_new(writer);
        entity_ready(free, e);
        if (prefab >= 0) {
            model[free].prefab = (int16_t)prefab;
            model[free].data = prefabs[prefab].data; /* Instances own copies (Override). */
        }
        if (parent >= 0) {
            ecs_add_pair(writer, e, EcsChildOf, model[parent].entity);
            model[free].parent = (int16_t)parent;
        }
        return free;
    }
    case 3:
        if (slot < 0) return -1;
        ecs_delete(writer, model[slot].entity);
        if (deferring) model_doom(slot); else model_delete(slot);
        return slot;
    case 4:
    case 5:
    case 6: {
        if (slot < 0) return -1;
        Data *d = &model[slot].data;
        ecs_entity_t e = model[slot].entity;
        if (op == 4) {
            d->position = random_position();
            d->has_position = true;
            ecs_set_ptr(writer, e, Position, &d->position);
        } else if (op == 5) {
            d->velocity = random_velocity();
            d->has_velocity = true;
            ecs_set_ptr(writer, e, Velocity, &d->velocity);
        } else {
            d->health = 1 + (int32_t)det_random_below(5);
            d->has_health = true;
            ecs_set(writer, e, Health, {d->health});
        }
        return slot;
    }
    case 7: {
        if (slot < 0 || model[slot].prefab >= 0) return -1; /* An instance's copies stay. */
        Data *d = &model[slot].data;
        ecs_entity_t e = model[slot].entity;
        switch (det_random_below(3)) {
        case 0: ecs_remove(writer, e, Position); d->has_position = false; break;
        case 1: ecs_remove(writer, e, Velocity); d->has_velocity = false; break;
        default: ecs_remove(writer, e, Health); d->has_health = false; break;
        }
        return slot;
    }
    case 8: {
        if (slot < 0) return -1;
        int t = (int)det_random_below(tags_max);
        Data *d = &model[slot].data;
        bool has = (d->tags >> t) & 1;
        if (has && model[slot].prefab >= 0) return -1;
        if (has) ecs_remove_id(writer, model[slot].entity, tags[t]); else ecs_add_id(writer, model[slot].entity, tags[t]);
        d->tags ^= (uint8_t)(1u << t);
        return slot;
    }
    case 9: {
        if (slot < 0) return -1;
        int target = pick_alive();
        if (target < 0 || det_random_below(4) == 0) {
            ecs_remove_pair(writer, model[slot].entity, likes, EcsWildcard);
            model[slot].likes = -1;
        } else {
            ecs_add_pair(writer, model[slot].entity, likes, model[target].entity); /* Exclusive. */
            model[slot].likes = (int16_t)target;
        }
        return slot;
    }
    default: {
        if (slot < 0) return -1;
        int parent = pick_alive();
        if (parent < 0 || det_random_below(4) == 0) {
            ecs_remove_pair(writer, model[slot].entity, EcsChildOf, EcsWildcard);
            model[slot].parent = -1;
        } else if (!descends_from(parent, slot)) {
            ecs_add_pair(writer, model[slot].entity, EcsChildOf, model[parent].entity);
            model[slot].parent = (int16_t)parent;
        }
        return slot;
    }
    }
}

/* A batch of operations through stage 0 in readonly mode (as a system's writes are queued): they
 * merge as readonly mode ends, and the model's deletions land there, as Flecs's. */
static void batch(void) {
    int touched[batch_max];
    size_t count = 1 + det_random_below(batch_max);
    deferring = true;
    ecs_readonly_begin(world, false);
    writer = ecs_get_stage(world, 0);
    for (size_t i = 0; i < count; i++) touched[i] = operate();
    writer = world;
    ecs_readonly_end(world);
    deferring = false;
    bool deleted = false;
    for (int slot = 0; slot < slots_max; slot++) {
        if (!model[slot].doomed) continue;
        model[slot].doomed = false;
        if (alive(slot)) {
            model_delete(slot);
            deleted = true;
        }
    }
    DET_SOMETIMES(deleted, "a deferred batch deletes entities", NULL);
    for (size_t i = 0; i < count; i++) if (touched[i] >= 0) check_slot(touched[i]);
}

/* Frames of the systems: Move, then Decay (deletions at the merge). */
static void frames(void) {
    int count = 1 + (int)det_random_below(frames_max);
    for (int f = 0; f < count; f++) {
        frame += 1;
        atomic_store(&frame_stages, 0);
        ecs_progress(world, 1.0f);
        DET_SOMETIMES(__builtin_popcount(atomic_load(&frame_stages)) > 1, "a frame runs systems on several threads", NULL);
        for (int slot = 0; slot < slots_max; slot++) {
            if (!alive(slot)) continue;
            Data *d = &model[slot].data;
            if (d->has_position && d->has_velocity) {
                d->position.x += d->velocity.x;
                d->position.y += d->velocity.y;
            }
        }
        for (int slot = 0; slot < slots_max; slot++) {
            if (!alive(slot)) continue;
            Data *d = &model[slot].data;
            if (d->has_health && (d->tags & 1)) d->health -= 1;
        }
        for (int slot = 0; slot < slots_max; slot++) {
            if (alive(slot) && model[slot].data.has_health && (model[slot].data.tags & 1) && model[slot].data.health <= 0) {
                model_delete(slot);
            }
        }
    }
}

/* A round ------------------------------------------------------------------------------------- */

static void world_make(void) {
    world = ecs_init();
    writer = world;
    ECS_COMPONENT_DEFINE(world, Position);
    ECS_COMPONENT_DEFINE(world, Velocity);
    ECS_COMPONENT_DEFINE(world, Health);
    ECS_COMPONENT_DEFINE(world, Slot);
    for (int t = 0; t < tags_max; t++) tags[t] = ecs_new(world);
    likes = ecs_new(world);
    ecs_add_id(world, likes, EcsExclusive);
    ecs_system(world, {
        .entity = ecs_entity(world, {.name = "Move"}),
        .phase = EcsOnUpdate,
        .query.terms = {{.id = ecs_id(Position)}, {.id = ecs_id(Velocity), .inout = EcsIn}, {.id = ecs_id(Slot), .inout = EcsIn}},
        .callback = Move,
        .multi_threaded = true,
    });
    ecs_system(world, {
        .entity = ecs_entity(world, {.name = "Decay"}),
        .phase = EcsOnUpdate,
        .query.terms = {{.id = ecs_id(Health)}, {.id = tags[0]}, {.id = ecs_id(Slot), .inout = EcsIn}},
        .callback = Decay,
        .multi_threaded = true,
    });
    ecs_observer(world, {.query.terms = {{.id = ecs_id(Position)}}, .events = {EcsOnSet}, .callback = PositionSet});
    ecs_observer(world, {.query.terms = {{.id = ecs_id(Health)}}, .events = {EcsOnRemove}, .callback = HealthRemoved});
    query_moving = ecs_query(world, {
        .terms = {{.id = ecs_id(Position)}, {.id = ecs_id(Velocity)}},
        .cache_kind = EcsQueryCacheAuto,
    });
    query_still = ecs_query(world, {
        .terms = {{.id = ecs_id(Position)}, {.id = tags[1]}, {.id = ecs_id(Velocity), .oper = EcsNot}},
        .cache_kind = EcsQueryCacheNone,
    });
    for (int p = 0; p < prefabs_max; p++) {
        Prefab *prefab = &prefabs[p];
        prefab->entity = ecs_new_w_id(world, EcsPrefab);
        memset(&prefab->data, 0, sizeof prefab->data);
        if (det_random_below(2)) {
            prefab->data.has_position = true;
            prefab->data.position = random_position();
            ecs_set_ptr(world, prefab->entity, Position, &prefab->data.position);
        }
        if (det_random_below(2)) {
            prefab->data.has_velocity = true;
            prefab->data.velocity = random_velocity();
            ecs_set_ptr(world, prefab->entity, Velocity, &prefab->data.velocity);
        }
        for (int t = 0; t < tags_max; t++) {
            if (det_random_below(3) != 0) continue;
            prefab->data.tags |= (uint8_t)(1u << t);
            ecs_add_id(world, prefab->entity, tags[t]);
        }
    }
    memset(model, 0, sizeof model);
    for (int slot = 0; slot < slots_max; slot++) {
        model[slot].parent = -1;
        model[slot].likes = -1;
        model[slot].prefab = -1;
    }
    threads = (int)det_random_below(threads_max + 1);
    if (threads > 0) ecs_set_threads(world, threads);
}

static void round_run(void) {
    atomic_store(&hook_random, det_random_u64() | 1);
    world_make();
    size_t steps = steps_min + det_random_below(steps_max - steps_min);
    char details[96];
    snprintf(details, sizeof details, "{\"threads\":%d,\"steps\":%zu}", threads, steps);
    det_event("flecs_round", details);
    for (size_t step = 0; step < steps; step++) {
        switch (det_random_below(10)) {
        case 0: frames(); break;
        case 1: batch(); break;
        default: {
            int slot = operate();
            if (slot >= 0) check_slot(slot);
        }
        }
        if (step % check_every == 0) check_all();
    }
    check_all();
    DET_SOMETIMES(threads > 1, "a world with worker threads is torn down", NULL);
    ecs_query_fini(query_moving); /* Queries are the program's to free (a sanitize build */
    ecs_query_fini(query_still);  /* checks every allocation is given back). */
    ecs_fini(world);
    world = NULL;
    DET_REACHABLE("a round runs to the end", NULL);
}

int main(int argc, char **argv) {
    long rounds = argc > 1 ? atol(argv[1]) : -1; /* Until the timeline ends. */
    os_hooks();
    ecs_log_set_level(-1);
    for (long round = 0; rounds < 0 || round < rounds; round++) round_run();
    return 0;
}
