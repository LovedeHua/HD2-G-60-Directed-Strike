/* Isolated ABI fixture only. Never loaded by a game addon. */
#include <stdint.h>
#include <string.h>
#define EXPORT __declspec(dllexport)
static _Alignas(8) unsigned char entities[4][24], records[4][0x1f8], movements[4][0xa8];
static unsigned char *entity=entities[0], *record=records[0], *movement=movements[0];
static unsigned clear_count, orbit_count, bad_args, mode, point_count, valid_count, dead_id;
static void put32(unsigned char *p, uint32_t v) { memcpy(p,&v,4); }
static void putf(unsigned char *p, float v) { memcpy(p,&v,4); }
static uint32_t bits(float v) { uint32_t b; memcpy(&b,&v,4); return b; }
EXPORT void fixture_reset(unsigned m) {
    memset(entities,0,sizeof entities); memset(records,0,sizeof records); memset(movements,0,sizeof movements);
    put32(entity,0x3e55bf62); put32(entity+4,0x8e325c93); put32(entity+8,547); put32(entity+16,77);
    put32(record,4); put32(record+8,4); put32(record+0x18,521);
    put32(record+0x60,1); put32(record+0x68,547); put32(record+0x70,521); record[0x78]=1;
    put32(record+0x188,1000000); putf(movement+0x60,99);
    for (unsigned i=1;i<4;++i) {
        memcpy(entities[i],entity,24); memcpy(records[i],record,0x1f8); memcpy(movements[i],movement,0xa8);
        put32(entities[i]+8,547+i); put32(records[i]+0x68,547+i);
    }
    clear_count=orbit_count=bad_args=point_count=valid_count=dead_id=0; mode=m;
}
EXPORT void *fixture_entity(void) { return entity; }
EXPORT void *fixture_record(void) { return record; }
EXPORT void *fixture_movement(void) { return movement; }
EXPORT void *fixture_entity_at(unsigned i) { return i<4 ? entities[i] : 0; }
EXPORT void *fixture_record_at(unsigned i) { return i<4 ? records[i] : 0; }
EXPORT void *fixture_movement_at(unsigned i) { return i<4 ? movements[i] : 0; }
static int pair_index(void **pair) {
    if (pair) for (int i=0;i<4;++i) if (pair[0]==entities[i] && pair[1]==records[i]+8) return i;
    ++bad_args; return -1;
}
EXPORT unsigned fixture_clears(void) { return clear_count; }
EXPORT unsigned fixture_orbits(void) { return orbit_count; }
EXPORT unsigned fixture_bad_args(void) { return bad_args; }
EXPORT unsigned fixture_points(void) { return point_count; }
EXPORT unsigned fixture_validations(void) { return valid_count; }
EXPORT void fixture_mode(unsigned value) { mode=value; }
EXPORT void fixture_dead(unsigned value) { dead_id=value; }
EXPORT _Bool fixture_target_valid(void *unused, uint32_t id, const void *target) {
    ++valid_count;
    if (unused || id<521 || id>526 || !target) { ++bad_args; return 0; }
    return mode!=5 && id!=dead_id;
}
EXPORT void fixture_clear(void **pair, const void *candidate) {
    int index=pair_index(pair); if (index<0) return;
    unsigned char *record=records[index];
    if (candidate) {
        ++point_count;
        if (mode==6) return;
        uint32_t id; memcpy(&id,candidate,4);
        if (id && (id<521 || id>526)) { ++bad_args; return; }
        memcpy(record+0x18,candidate,80); record[0x78]=1;
        put32(record+0x70,id); put32(record+0x28,2000000);
        if (mode==7) put32(record+0x188,2000000);
        return;
    }
    ++clear_count;
    if (mode==1) return;
    put32(record+0x18,0); put32(record+0x60,0); put32(record+0x70,0); record[0x78]=0;
    if (mode==2) put32(record+0x188,2000000);
}
/* A model of the reviewed position-only guidance/proximity consumer, not game code. */
EXPORT unsigned fixture_consume_point(float x, float y, float z) {
    if (!record[0x78]) return 0;
    float p[3]; memcpy(p,record+0x1c,12);
    memcpy(movement+0x60,p,12); putf(movement+0x68,p[2]+0.25f);
    float dx=p[0]-x,dy=p[1]-y,dz=p[2]-z;
    return (dx*dx+dy*dy+dz*dz<=6.25f) && (record[0x64]!=0);
}
EXPORT void fixture_orbit(void **pair, float a, float b, float c) {
    ++orbit_count;
    int index=pair_index(pair); if (index<0) return;
    unsigned char *record=records[index], *movement=movements[index];
    if (record[0x78] ||
        bits(a)!=0x41200000 || bits(b)!=0x40200000 || bits(c)!=0x3f99999a) { ++bad_args; return; }
    if (mode==3) return;
    putf(movement+0x60,(float)orbit_count); putf(movement+0x64,2); putf(movement+0x68,3);
    if (mode==4) put32(record+8,3);
}
/* Additional isolated executors for the arrival-fuse experiment. */
static _Alignas(8) unsigned char fuse_states[4][64], fuse_networks[4][56];
static unsigned char *fuse_state=fuse_states[0], *fuse_network=fuse_networks[0];
static uint32_t retire_count, retire_queue[2048], explode_count, aim_count;
EXPORT void fixture_fuse_reset(void) {
    memset(fuse_states,0,sizeof fuse_states);memset(fuse_networks,0,sizeof fuse_networks);
    for (unsigned i=0;i<4;++i) {
        put32(fuse_states[i]+0x38,2);put32(entities[i]+12,9+i);put32(entities[i]+20,1);
    }
    retire_count=explode_count=aim_count=0;
}
EXPORT void *fixture_fuse_state(void) { return fuse_state; }
EXPORT void *fixture_fuse_network(void) { return fuse_network; }
EXPORT void *fixture_fuse_state_at(unsigned i) { return i<4 ? fuse_states[i] : 0; }
EXPORT void *fixture_fuse_network_at(unsigned i) { return i<4 ? fuse_networks[i] : 0; }
EXPORT void *fixture_retire_count(void) { return &retire_count; }
EXPORT void *fixture_retire_queue(void) { return retire_queue; }
EXPORT unsigned fixture_explosions(void) { return explode_count; }
EXPORT void fixture_explode(void *manager,uint32_t id,uint32_t source,void *extra) {
    ++explode_count;
    if ((uintptr_t)manager!=0x42000000 || id<547 || id>550 || source!=0xdeadbeef || extra) {++bad_args;return;}
    if (mode==8) return;
    fuse_networks[id-547][1]=1;
    if (mode==9) put32(records[id-547]+0x188,2000000);
}
EXPORT void *fixture_aim(void *out,void **pair,const void *own) {
    ++aim_count;
    int index=pair_index(pair); if (index<0) return 0;
    if (!out || !own) {++bad_args;return 0;}
    memcpy(out,records[index]+0x1c,12);return out;
}
EXPORT void fixture_remove(void *root,uint32_t id) {
    if (!root || id<547 || id>550 || retire_count>=2048) {++bad_args;return;}
    retire_queue[retire_count++]=8+id-547;
}
