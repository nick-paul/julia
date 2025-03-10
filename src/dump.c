// This file is a part of Julia. License is MIT: https://julialang.org/license

/*
  saving and restoring precompiled modules (.ji files)
*/
#include <stdlib.h>
#include <string.h>

#include "julia.h"
#include "julia_internal.h"
#include "julia_gcext.h"
#include "builtin_proto.h"
#include "serialize.h"

#ifndef _OS_WINDOWS_
#include <dlfcn.h>
#endif

#include "valgrind.h"
#include "julia_assert.h"

#ifdef __cplusplus
extern "C" {
#endif

// This file, together with ircode.c, allows (de)serialization between
// modules and *.ji cache files. `jl_save_incremental` gets called as the final step
// during package precompilation, and `_jl_restore_incremental` by `using SomePkg`
// whenever `SomePkg` has not yet been loaded.

// Types, methods, and method instances form a graph that may have cycles, so
// serialization has to break these cycles. This is handled via "backreferences,"
// referring to already (de)serialized items by an index. It is critial to ensure
// that the indexes of these backreferences align precisely during serialization
// and deserialization, to ensure that these integer indexes mean the same thing
// under both circumstances. Consequently, if you are modifying this file, be
// careful to match the sequence, if necessary reserving space for something that will
// be updated later.

// It is also necessary to save & restore references to externally-defined objects,
// e.g., for package methods that call methods defined in Base or elsewhere.
// Consequently during deserialization there's a distinction between "reference"
// types, methods, and method instances (essentially like a GlobalRef),
// and "recached" version that refer to the actual entity in the running session.
// We complete deserialization before beginning the process of recaching,
// because we need the backreferences during deserialization and the actual
// objects during recaching.

// Finally, because our backedge graph is not bidirectional, special handling is
// required to identify backedges from external methods that call internal methods.
// These get set aside and restored at the end of deserialization.

// Note that one should prioritize deserialization performance over serialization performance,
// since deserialization may be performed much more often than serialization.


// TODO: put WeakRefs on the weak_refs list during deserialization
// TODO: handle finalizers

// type => tag hash for a few core types (e.g., Expr, PhiNode, etc)
static htable_t ser_tag;
// tag => type mapping, the reverse of ser_tag
static jl_value_t *deser_tag[256];
// hash of some common symbols, encoded as CommonSym_tag plus 1 byte
static htable_t common_symbol_tag;
static jl_value_t *deser_symbols[256];

// table of all objects that have been deserialized, indexed by pos
// (the order in the serializer stream). the low
// bit is reserved for flagging certain entries and pos is
// left shift by 1
static htable_t backref_table;
static int backref_table_numel;
static arraylist_t backref_list;
static htable_t new_code_instance_validate;

// list of (jl_value_t **loc, size_t pos) entries
// for anything that was flagged by the deserializer for later
// type-rewriting of some sort. pos is the index in backref_list.
static arraylist_t flagref_list;
// ref => value hash for looking up the "real" entity from
// the deserialized ref. Used for entities that must be unique,
// like types, methods, and method instances
static htable_t uniquing_table;

// list of (size_t pos, (void *f)(jl_value_t*)) entries
// for the serializer to mark values in need of rework by function f
// during deserialization later
static arraylist_t reinit_list;

// list of stuff that is being serialized
// This is not quite globally rooted, but we take care to only
// ever assigned rooted values here.
static jl_array_t *serializer_worklist JL_GLOBALLY_ROOTED;
// external MethodInstances we want to serialize
static htable_t external_mis;
// Inference tracks newly-inferred MethodInstances during precompilation
// and registers them by calling jl_set_newly_inferred
static jl_array_t *newly_inferred JL_GLOBALLY_ROOTED;

// New roots to add to Methods. These can't be added until after
// recaching is complete, so we have to hold on to them separately
// Stored as method => (worklist_key, roots)
static htable_t queued_method_roots;

// inverse of backedges graph (caller=>callees hash)
htable_t edges_map;

// list of requested ccallable signatures
static arraylist_t ccallable_list;

typedef struct {
    ios_t *s;
    jl_ptls_t ptls;
    jl_array_t *loaded_modules_array;
} jl_serializer_state;

static jl_value_t *jl_idtable_type = NULL;
static jl_typename_t *jl_idtable_typename = NULL;
static jl_value_t *jl_bigint_type = NULL;
static int gmp_limb_size = 0;

static void write_uint64(ios_t *s, uint64_t i) JL_NOTSAFEPOINT
{
    ios_write(s, (char*)&i, 8);
}

static void write_float64(ios_t *s, double x) JL_NOTSAFEPOINT
{
    write_uint64(s, *((uint64_t*)&x));
}

void *jl_lookup_ser_tag(jl_value_t *v)
{
    return ptrhash_get(&ser_tag, v);
}

void *jl_lookup_common_symbol(jl_value_t *v)
{
    return ptrhash_get(&common_symbol_tag, v);
}

jl_value_t *jl_deser_tag(uint8_t tag)
{
    return deser_tag[tag];
}

jl_value_t *jl_deser_symbol(uint8_t tag)
{
    return deser_symbols[tag];
}

uint64_t jl_worklist_key(jl_array_t *worklist)
{
    assert(jl_is_array(worklist));
    size_t len = jl_array_len(worklist);
    if (len > 0) {
        jl_module_t *topmod = (jl_module_t*)jl_array_ptr_ref(worklist, len-1);
        assert(jl_is_module(topmod));
        return topmod->build_id;
    }
    return 0;
}

// --- serialize ---

#define jl_serialize_value(s, v) jl_serialize_value_((s), (jl_value_t*)(v), 0)
static void jl_serialize_value_(jl_serializer_state *s, jl_value_t *v, int as_literal) JL_GC_DISABLED;

static void jl_serialize_cnull(jl_serializer_state *s, jl_value_t *t)
{
    backref_table_numel++;
    write_uint8(s->s, TAG_CNULL);
    jl_serialize_value(s, t);
}

static int module_in_worklist(jl_module_t *mod) JL_NOTSAFEPOINT
{
    int i, l = jl_array_len(serializer_worklist);
    for (i = 0; i < l; i++) {
        jl_module_t *workmod = (jl_module_t*)jl_array_ptr_ref(serializer_worklist, i);
        if (jl_is_module(workmod) && jl_is_submodule(mod, workmod))
            return 1;
    }
    return 0;
}

static int method_instance_in_queue(jl_method_instance_t *mi)
{
    return ptrhash_get(&external_mis, mi) != HT_NOTFOUND;
}

// compute whether a type references something internal to worklist
// and thus could not have existed before deserialize
// and thus does not need delayed unique-ing
static int type_in_worklist(jl_datatype_t *dt) JL_NOTSAFEPOINT
{
    if (module_in_worklist(dt->name->module))
        return 1;
    int i, l = jl_svec_len(dt->parameters);
    for (i = 0; i < l; i++) {
        jl_value_t *p = jl_unwrap_unionall(jl_tparam(dt, i));
        // TODO: what about Union and TypeVar??
        if (type_in_worklist((jl_datatype_t*)(jl_is_datatype(p) ? p : jl_typeof(p))))
            return 1;
    }
    return 0;
}

static int type_recursively_external(jl_datatype_t *dt);

static int type_parameter_recursively_external(jl_value_t *p0) JL_NOTSAFEPOINT
{
    if (!jl_is_concrete_type(p0))
        return 0;
    jl_datatype_t *p = (jl_datatype_t*)p0;
    //while (jl_is_unionall(p)) {
    //    if (!type_parameter_recursively_external(((jl_unionall_t*)p)->var->lb))
    //        return 0;
    //    if (!type_parameter_recursively_external(((jl_unionall_t*)p)->var->ub))
    //        return 0;
    //    p = (jl_datatype_t*)((jl_unionall_t*)p)->body;
    //}
    if (module_in_worklist(p->name->module))
        return 0;
    if (p->name->wrapper != (jl_value_t*)p0) {
        if (!type_recursively_external(p))
            return 0;
    }
    return 1;
}

// returns true if all of the parameters are tag 6 or 7
static int type_recursively_external(jl_datatype_t *dt) JL_NOTSAFEPOINT
{
    if (!dt->isconcretetype)
        return 0;
    if (jl_svec_len(dt->parameters) == 0)
        return 1;

    int i, l = jl_svec_len(dt->parameters);
    for (i = 0; i < l; i++) {
        if (!type_parameter_recursively_external(jl_tparam(dt, i)))
            return 0;
    }
    return 1;
}

// When we infer external method instances, ensure they link back to the
// package. Otherwise they might be, e.g., for external macros
static int has_backedge_to_worklist(jl_method_instance_t *mi, htable_t *visited)
{
    void **bp = ptrhash_bp(visited, mi);
    // HT_NOTFOUND: not yet analyzed
    // HT_NOTFOUND + 1: doesn't link back
    // HT_NOTFOUND + 2: does link back
    if (*bp != HT_NOTFOUND)
        return (char*)*bp - (char*)HT_NOTFOUND - 1;
    *bp = (void*)((char*)HT_NOTFOUND + 1);  // preliminarily mark as "not found"
    jl_module_t *mod = mi->def.module;
    if (jl_is_method(mod))
        mod = ((jl_method_t*)mod)->module;
    assert(jl_is_module(mod));
    if (mi->precompiled || module_in_worklist(mod)) {
        *bp = (void*)((char*)HT_NOTFOUND + 2);      // found
        return 1;
    }
    if (!mi->backedges) {
        return 0;
    }
    size_t i, n = jl_array_len(mi->backedges);
    for (i = 0; i < n; i++) {
        jl_method_instance_t *be = (jl_method_instance_t*)jl_array_ptr_ref(mi->backedges, i);
        if (has_backedge_to_worklist(be, visited)) {
            bp = ptrhash_bp(visited, mi);           // re-acquire since rehashing might change the location
            *bp = (void*)((char*)HT_NOTFOUND + 2);  // found
            return 1;
        }
    }
    return 0;
}

// given the list of MethodInstances that were inferred during the
// build, select those that are external and have at least one
// relocatable CodeInstance.
static size_t queue_external_mis(jl_array_t *list)
{
    size_t i, n = 0;
    htable_t visited;
    if (list) {
        assert(jl_is_array(list));
        size_t n0 = jl_array_len(list);
        htable_new(&visited, n0);
        for (i = 0; i < n0; i++) {
            jl_method_instance_t *mi = (jl_method_instance_t*)jl_array_ptr_ref(list, i);
            assert(jl_is_method_instance(mi));
            if (jl_is_method(mi->def.value)) {
                jl_method_t *m = mi->def.method;
                if (!module_in_worklist(m->module)) {
                    jl_code_instance_t *ci = mi->cache;
                    int relocatable = 0;
                    while (ci) {
                        relocatable |= ci->relocatability;
                        ci = ci->next;
                    }
                    if (relocatable && ptrhash_get(&external_mis, mi) == HT_NOTFOUND) {
                        if (has_backedge_to_worklist(mi, &visited)) {
                            ptrhash_put(&external_mis, mi, mi);
                            n++;
                        }
                    }
                }
            }
        }
        htable_free(&visited);
    }
    return n;
}

static void jl_serialize_datatype(jl_serializer_state *s, jl_datatype_t *dt) JL_GC_DISABLED
{
    int tag = 0;
    int internal = module_in_worklist(dt->name->module);
    if (!internal && jl_unwrap_unionall(dt->name->wrapper) == (jl_value_t*)dt) {
        tag = 6; // external primary type
    }
    else if (jl_is_tuple_type(dt) ? !dt->isconcretetype : dt->hasfreetypevars) {
        tag = 0; // normal struct
    }
    else if (internal) {
        if (jl_unwrap_unionall(dt->name->wrapper) == (jl_value_t*)dt) // comes up often since functions create types
            tag = 5; // internal, and not in the typename cache
        else
            tag = 10; // anything else that's internal (just may need recaching)
    }
    else if (type_recursively_external(dt)) {
        tag = 7; // external type that can be immediately recreated (with apply_type)
    }
    else if (type_in_worklist(dt)) {
        tag = 11; // external, but definitely new (still needs caching, but not full unique-ing)
    }
    else {
        // this is eligible for (and possibly requires) unique-ing later,
        // so flag this in the backref table as special
        uintptr_t *bp = (uintptr_t*)ptrhash_bp(&backref_table, dt);
        assert(*bp != (uintptr_t)HT_NOTFOUND);
        *bp |= 1;
        tag = 12;
    }

    char *dtname = jl_symbol_name(dt->name->name);
    size_t dtnl = strlen(dtname);
    if (dtnl > 4 && strcmp(&dtname[dtnl - 4], "##kw") == 0 && !internal && tag != 0) {
        /* XXX: yuck, this is horrible, but the auto-generated kw types from the serializer isn't a real type, so we *must* be very careful */
        assert(tag == 6); // other struct types should never exist
        tag = 9;
        if (jl_type_type_mt->kwsorter != NULL && dt == (jl_datatype_t*)jl_typeof(jl_type_type_mt->kwsorter)) {
            dt = jl_datatype_type; // any representative member with this MethodTable
        }
        else if (jl_nonfunction_mt->kwsorter != NULL && dt == (jl_datatype_t*)jl_typeof(jl_nonfunction_mt->kwsorter)) {
            dt = jl_symbol_type; // any representative member with this MethodTable
        }
        else {
            // search for the representative member of this MethodTable
            jl_methtable_t *mt = dt->name->mt;
            size_t l = strlen(jl_symbol_name(mt->name));
            char *prefixed;
            prefixed = (char*)malloc_s(l + 2);
            prefixed[0] = '#';
            strcpy(&prefixed[1], jl_symbol_name(mt->name));
            // remove ##kw suffix
            prefixed[l-3] = 0;
            jl_sym_t *tname = jl_symbol(prefixed);
            free(prefixed);
            jl_value_t *primarydt = jl_get_global(mt->module, tname);
            if (!primarydt)
                primarydt = jl_get_global(mt->module, mt->name);
            primarydt = jl_unwrap_unionall(primarydt);
            assert(jl_is_datatype(primarydt));
            assert(primarydt == (jl_value_t*)jl_any_type || jl_typeof(((jl_datatype_t*)primarydt)->name->mt->kwsorter) == (jl_value_t*)dt);
            dt = (jl_datatype_t*)primarydt;
        }
    }

    write_uint8(s->s, TAG_DATATYPE);
    write_uint8(s->s, tag);
    if (tag == 6 || tag == 7) {
        // for tag==6, copy its typevars in case there are references to them elsewhere
        jl_serialize_value(s, dt->name);
        jl_serialize_value(s, dt->parameters);
        return;
    }
    if (tag == 9) {
        jl_serialize_value(s, dt);
        return;
    }

    write_int32(s->s, dt->size);
    int has_instance = (dt->instance != NULL);
    int has_layout = (dt->layout != NULL);
    write_uint8(s->s, has_layout | (has_instance << 1));
    write_uint8(s->s, dt->hasfreetypevars
            | (dt->isconcretetype << 1)
            | (dt->isdispatchtuple << 2)
            | (dt->isbitstype << 3)
            | (dt->zeroinit << 4)
            | (dt->has_concrete_subtype << 5)
            | (dt->cached_by_hash << 6));
    write_int32(s->s, dt->hash);

    if (has_layout) {
        uint8_t layout = 0;
        if (dt->layout == ((jl_datatype_t*)jl_unwrap_unionall((jl_value_t*)jl_array_type))->layout) {
            layout = 1;
        }
        else if (dt->layout == jl_nothing_type->layout) {
            layout = 2;
        }
        else if (dt->layout == ((jl_datatype_t*)jl_unwrap_unionall((jl_value_t*)jl_pointer_type))->layout) {
            layout = 3;
        }
        write_uint8(s->s, layout);
        if (layout == 0) {
            uint32_t nf = dt->layout->nfields;
            uint32_t np = dt->layout->npointers;
            size_t fieldsize = jl_fielddesc_size(dt->layout->fielddesc_type);
            ios_write(s->s, (const char*)dt->layout, sizeof(*dt->layout));
            size_t fldsize = nf * fieldsize;
            if (dt->layout->first_ptr != -1)
                fldsize += np << dt->layout->fielddesc_type;
            ios_write(s->s, (const char*)(dt->layout + 1), fldsize);
        }
    }

    if (has_instance)
        jl_serialize_value(s, dt->instance);
    jl_serialize_value(s, dt->name);
    jl_serialize_value(s, dt->parameters);
    jl_serialize_value(s, dt->super);
    jl_serialize_value(s, dt->types);
}

static void jl_serialize_module(jl_serializer_state *s, jl_module_t *m)
{
    write_uint8(s->s, TAG_MODULE);
    jl_serialize_value(s, m->name);
    size_t i;
    if (!module_in_worklist(m)) {
        if (m == m->parent) {
            // top-level module
            write_int8(s->s, 2);
            int j = 0;
            for (i = 0; i < jl_array_len(s->loaded_modules_array); i++) {
                jl_module_t *mi = (jl_module_t*)jl_array_ptr_ref(s->loaded_modules_array, i);
                if (!module_in_worklist(mi)) {
                    if (m == mi) {
                        write_int32(s->s, j);
                        return;
                    }
                    j++;
                }
            }
            assert(0 && "top level module not found in modules array");
        }
        else {
            write_int8(s->s, 1);
            jl_serialize_value(s, m->parent);
        }
        return;
    }
    write_int8(s->s, 0);
    jl_serialize_value(s, m->parent);
    void **table = m->bindings.table;
    for (i = 0; i < m->bindings.size; i += 2) {
        if (table[i+1] != HT_NOTFOUND) {
            jl_serialize_value(s, (jl_value_t*)table[i]);
            jl_binding_t *b = (jl_binding_t*)table[i+1];
            jl_serialize_value(s, b->name);
            jl_value_t *e = jl_atomic_load_relaxed(&b->value);
            if (!b->constp && e && jl_is_cpointer(e) && jl_unbox_voidpointer(e) != (void*)-1 && jl_unbox_voidpointer(e) != NULL)
                // reset Ptr fields to C_NULL (but keep MAP_FAILED / INVALID_HANDLE)
                jl_serialize_cnull(s, jl_typeof(e));
            else
                jl_serialize_value(s, e);
            jl_serialize_value(s, jl_atomic_load_relaxed(&b->globalref));
            jl_serialize_value(s, b->owner);
            jl_serialize_value(s, jl_atomic_load_relaxed(&b->ty));
            write_int8(s->s, (b->deprecated<<3) | (b->constp<<2) | (b->exportp<<1) | (b->imported));
        }
    }
    jl_serialize_value(s, NULL);
    write_int32(s->s, m->usings.len);
    for(i=0; i < m->usings.len; i++) {
        jl_serialize_value(s, (jl_value_t*)m->usings.items[i]);
    }
    write_uint8(s->s, m->istopmod);
    write_uint64(s->s, m->uuid.hi);
    write_uint64(s->s, m->uuid.lo);
    write_uint64(s->s, m->build_id);
    write_int32(s->s, m->counter);
    write_int32(s->s, m->nospecialize);
    write_uint8(s->s, m->optlevel);
    write_uint8(s->s, m->compile);
    write_uint8(s->s, m->infer);
    write_uint8(s->s, m->max_methods);
}

static int jl_serialize_generic(jl_serializer_state *s, jl_value_t *v) JL_GC_DISABLED
{
    if (v == NULL) {
        write_uint8(s->s, TAG_NULL);
        return 1;
    }

    void *tag = ptrhash_get(&ser_tag, v);
    if (tag != HT_NOTFOUND) {
        uint8_t t8 = (intptr_t)tag;
        if (t8 <= LAST_TAG)
            write_uint8(s->s, 0);
        write_uint8(s->s, t8);
        return 1;
    }

    if (jl_is_symbol(v)) {
        void *idx = ptrhash_get(&common_symbol_tag, v);
        if (idx != HT_NOTFOUND) {
            write_uint8(s->s, TAG_COMMONSYM);
            write_uint8(s->s, (uint8_t)(size_t)idx);
            return 1;
        }
    }
    else if (v == (jl_value_t*)jl_core_module) {
        write_uint8(s->s, TAG_CORE);
        return 1;
    }
    else if (v == (jl_value_t*)jl_base_module) {
        write_uint8(s->s, TAG_BASE);
        return 1;
    }

    if (jl_typeis(v, jl_string_type) && jl_string_len(v) == 0) {
        jl_serialize_value(s, jl_an_empty_string);
        return 1;
    }
    else if (!jl_is_uint8(v)) {
        void **bp = ptrhash_bp(&backref_table, v);
        if (*bp != HT_NOTFOUND) {
            uintptr_t pos = (char*)*bp - (char*)HT_NOTFOUND - 1;
            if (pos < 65536) {
                write_uint8(s->s, TAG_SHORT_BACKREF);
                write_uint16(s->s, pos);
            }
            else {
                write_uint8(s->s, TAG_BACKREF);
                write_int32(s->s, pos);
            }
            return 1;
        }
        intptr_t pos = backref_table_numel++;
        if (((jl_datatype_t*)(jl_typeof(v)))->name == jl_idtable_typename) {
            // will need to rehash this, later (after types are fully constructed)
            arraylist_push(&reinit_list, (void*)pos);
            arraylist_push(&reinit_list, (void*)1);
        }
        if (jl_is_module(v)) {
            jl_module_t *m = (jl_module_t*)v;
            if (module_in_worklist(m) && !module_in_worklist(m->parent)) {
                // will need to reinsert this into parent bindings, later (in case of any errors during reinsert)
                arraylist_push(&reinit_list, (void*)pos);
                arraylist_push(&reinit_list, (void*)2);
            }
        }
        // TypeMapLevels need to be rehashed
        if (jl_is_mtable(v)) {
            arraylist_push(&reinit_list, (void*)pos);
            arraylist_push(&reinit_list, (void*)3);
        }
        pos <<= 1;
        ptrhash_put(&backref_table, v, (char*)HT_NOTFOUND + pos + 1);
    }

    return 0;
}

static void jl_serialize_code_instance(jl_serializer_state *s, jl_code_instance_t *codeinst, int skip_partial_opaque, int internal) JL_GC_DISABLED
{
    if (internal > 2) {
        while (codeinst && !codeinst->relocatability)
            codeinst = codeinst->next;
    }
    if (jl_serialize_generic(s, (jl_value_t*)codeinst)) {
        return;
    }

    int validate = 0;
    if (codeinst->max_world == ~(size_t)0)
        validate = 1; // can check on deserialize if this cache entry is still valid
    int flags = validate << 0;
    if (codeinst->invoke == jl_fptr_const_return)
        flags |= 1 << 2;
    if (codeinst->precompile)
        flags |= 1 << 3;

    // CodeInstances with PartialOpaque return type are currently not allowed
    // to be cached. We skip them in serialization here, forcing them to
    // be re-infered on reload.
    int write_ret_type = validate || codeinst->min_world == 0;
    if (write_ret_type && codeinst->rettype_const &&
            jl_typeis(codeinst->rettype_const, jl_partial_opaque_type)) {
        if (skip_partial_opaque) {
            jl_serialize_code_instance(s, codeinst->next, skip_partial_opaque, internal);
            return;
        }
        else {
            jl_error("Cannot serialize CodeInstance with PartialOpaque rettype");
        }
    }

    write_uint8(s->s, TAG_CODE_INSTANCE);
    write_uint8(s->s, flags);
    write_uint32(s->s, codeinst->ipo_purity_bits);
    write_uint32(s->s, codeinst->purity_bits);
    jl_serialize_value(s, (jl_value_t*)codeinst->def);
    if (write_ret_type) {
        jl_serialize_value(s, codeinst->inferred);
        jl_serialize_value(s, codeinst->rettype_const);
        jl_serialize_value(s, codeinst->rettype);
        jl_serialize_value(s, codeinst->argescapes);
    }
    else {
        // skip storing useless data
        jl_serialize_value(s, NULL);
        jl_serialize_value(s, NULL);
        jl_serialize_value(s, jl_any_type);
        jl_serialize_value(s, jl_nothing);
    }
    write_uint8(s->s, codeinst->relocatability);
    jl_serialize_code_instance(s, codeinst->next, skip_partial_opaque, internal);
}

enum METHOD_SERIALIZATION_MODE {
    METHOD_INTERNAL = 1,
    METHOD_EXTERNAL_MT = 2,
    METHOD_HAS_NEW_ROOTS = 4,
};

static void jl_serialize_value_(jl_serializer_state *s, jl_value_t *v, int as_literal) JL_GC_DISABLED
{
    if (jl_serialize_generic(s, v)) {
        return;
    }

    size_t i;
    if (jl_is_svec(v)) {
        size_t l = jl_svec_len(v);
        if (l <= 255) {
            write_uint8(s->s, TAG_SVEC);
            write_uint8(s->s, (uint8_t)l);
        }
        else {
            write_uint8(s->s, TAG_LONG_SVEC);
            write_int32(s->s, l);
        }
        for (i = 0; i < l; i++) {
            jl_serialize_value(s, jl_svecref(v, i));
        }
    }
    else if (jl_is_symbol(v)) {
        size_t l = strlen(jl_symbol_name((jl_sym_t*)v));
        if (l <= 255) {
            write_uint8(s->s, TAG_SYMBOL);
            write_uint8(s->s, (uint8_t)l);
        }
        else {
            write_uint8(s->s, TAG_LONG_SYMBOL);
            write_int32(s->s, l);
        }
        ios_write(s->s, jl_symbol_name((jl_sym_t*)v), l);
    }
    else if (jl_is_array(v)) {
        jl_array_t *ar = (jl_array_t*)v;
        jl_value_t *et = jl_tparam0(jl_typeof(ar));
        int isunion = jl_is_uniontype(et);
        if (ar->flags.ndims == 1 && ar->elsize <= 0x1f) {
            write_uint8(s->s, TAG_ARRAY1D);
            write_uint8(s->s, (ar->flags.ptrarray << 7) | (ar->flags.hasptr << 6) | (isunion << 5) | (ar->elsize & 0x1f));
        }
        else {
            write_uint8(s->s, TAG_ARRAY);
            write_uint16(s->s, ar->flags.ndims);
            write_uint16(s->s, (ar->flags.ptrarray << 15) | (ar->flags.hasptr << 14) | (isunion << 13) | (ar->elsize & 0x1fff));
        }
        for (i = 0; i < ar->flags.ndims; i++)
            jl_serialize_value(s, jl_box_long(jl_array_dim(ar,i)));
        jl_serialize_value(s, jl_typeof(ar));
        size_t l = jl_array_len(ar);
        if (ar->flags.ptrarray) {
            for (i = 0; i < l; i++) {
                jl_value_t *e = jl_array_ptr_ref(v, i);
                if (e && jl_is_cpointer(e) && jl_unbox_voidpointer(e) != (void*)-1 && jl_unbox_voidpointer(e) != NULL)
                    // reset Ptr elements to C_NULL (but keep MAP_FAILED / INVALID_HANDLE)
                    jl_serialize_cnull(s, jl_typeof(e));
                else
                    jl_serialize_value(s, e);
            }
        }
        else if (ar->flags.hasptr) {
            const char *data = (const char*)jl_array_data(ar);
            uint16_t elsz = ar->elsize;
            size_t j, np = ((jl_datatype_t*)et)->layout->npointers;
            for (i = 0; i < l; i++) {
                const char *start = data;
                for (j = 0; j < np; j++) {
                    uint32_t ptr = jl_ptr_offset((jl_datatype_t*)et, j);
                    const jl_value_t *const *fld = &((const jl_value_t *const *)data)[ptr];
                    if ((const char*)fld != start)
                        ios_write(s->s, start, (const char*)fld - start);
                    JL_GC_PROMISE_ROOTED(*fld);
                    jl_serialize_value(s, *fld);
                    start = (const char*)&fld[1];
                }
                data += elsz;
                if (data != start)
                    ios_write(s->s, start, data - start);
            }
        }
        else if (jl_is_cpointer_type(et)) {
            // reset Ptr elements to C_NULL
            const void **data = (const void**)jl_array_data(ar);
            for (i = 0; i < l; i++) {
                const void *e = data[i];
                if (e != (void*)-1)
                    e = NULL;
                ios_write(s->s, (const char*)&e, sizeof(e));
            }
        }
        else {
            ios_write(s->s, (char*)jl_array_data(ar), l * ar->elsize);
            if (jl_array_isbitsunion(ar))
                ios_write(s->s, jl_array_typetagdata(ar), l);
        }
    }
    else if (jl_is_datatype(v)) {
        jl_serialize_datatype(s, (jl_datatype_t*)v);
    }
    else if (jl_is_unionall(v)) {
        write_uint8(s->s, TAG_UNIONALL);
        jl_datatype_t *d = (jl_datatype_t*)jl_unwrap_unionall(v);
        if (jl_is_datatype(d) && d->name->wrapper == v &&
            !module_in_worklist(d->name->module)) {
            write_uint8(s->s, 1);
            jl_serialize_value(s, d->name->module);
            jl_serialize_value(s, d->name->name);
        }
        else {
            write_uint8(s->s, 0);
            jl_serialize_value(s, ((jl_unionall_t*)v)->var);
            jl_serialize_value(s, ((jl_unionall_t*)v)->body);
        }
    }
    else if (jl_is_typevar(v)) {
        write_uint8(s->s, TAG_TVAR);
        jl_serialize_value(s, ((jl_tvar_t*)v)->name);
        jl_serialize_value(s, ((jl_tvar_t*)v)->lb);
        jl_serialize_value(s, ((jl_tvar_t*)v)->ub);
    }
    else if (jl_is_method(v)) {
        write_uint8(s->s, TAG_METHOD);
        jl_method_t *m = (jl_method_t*)v;
        uint64_t key = 0;
        int serialization_mode = 0, nwithkey = 0;
        if (m->is_for_opaque_closure || module_in_worklist(m->module))
            serialization_mode |= METHOD_INTERNAL;
        if (!(serialization_mode & METHOD_INTERNAL)) {
            key = jl_worklist_key(serializer_worklist);
            nwithkey = nroots_with_key(m, key);
            if (nwithkey > 0)
                serialization_mode |= METHOD_HAS_NEW_ROOTS;
        }
        if (!(serialization_mode & METHOD_INTERNAL)) {
            // flag this in the backref table as special
            uintptr_t *bp = (uintptr_t*)ptrhash_bp(&backref_table, v);
            assert(*bp != (uintptr_t)HT_NOTFOUND);
            *bp |= 1;
        }
        jl_serialize_value(s, (jl_value_t*)m->sig);
        jl_serialize_value(s, (jl_value_t*)m->module);
        if (m->external_mt != NULL) {
            assert(jl_typeis(m->external_mt, jl_methtable_type));
            jl_methtable_t *mt = (jl_methtable_t*)m->external_mt;
            if (!module_in_worklist(mt->module)) {
                serialization_mode |= METHOD_EXTERNAL_MT;
            }
        }
        write_uint8(s->s, serialization_mode);
        if (serialization_mode & METHOD_EXTERNAL_MT) {
            // We reference this method table by module and binding
            jl_methtable_t *mt = (jl_methtable_t*)m->external_mt;
            jl_serialize_value(s, mt->module);
            jl_serialize_value(s, mt->name);
        }
        else {
            jl_serialize_value(s, (jl_value_t*)m->external_mt);
        }
        if (!(serialization_mode & METHOD_INTERNAL)) {
            if (serialization_mode & METHOD_HAS_NEW_ROOTS) {
                // Serialize the roots that belong to key
                write_uint64(s->s, key);
                write_int32(s->s, nwithkey);
                rle_iter_state rootiter = rle_iter_init(0);
                uint64_t *rletable = NULL;
                size_t nblocks2 = 0, nroots = jl_array_len(m->roots);
                if (m->root_blocks) {
                    rletable = (uint64_t*)jl_array_data(m->root_blocks);
                    nblocks2 = jl_array_len(m->root_blocks);
                }
                // this visits every item, if it becomes a bottlneck we could hop blocks
                while (rle_iter_increment(&rootiter, nroots, rletable, nblocks2))
                    if (rootiter.key == key)
                        jl_serialize_value(s, jl_array_ptr_ref(m->roots, rootiter.i));
            }
            return;
        }
        jl_serialize_value(s, m->specializations);
        jl_serialize_value(s, jl_atomic_load_relaxed(&m->speckeyset));
        jl_serialize_value(s, (jl_value_t*)m->name);
        jl_serialize_value(s, (jl_value_t*)m->file);
        write_int32(s->s, m->line);
        write_int32(s->s, m->called);
        write_int32(s->s, m->nargs);
        write_int32(s->s, m->nospecialize);
        write_int32(s->s, m->nkw);
        write_int8(s->s, m->isva);
        write_int8(s->s, m->pure);
        write_int8(s->s, m->is_for_opaque_closure);
        write_int8(s->s, m->constprop);
        write_uint8(s->s, m->purity.bits);
        jl_serialize_value(s, (jl_value_t*)m->slot_syms);
        jl_serialize_value(s, (jl_value_t*)m->roots);
        jl_serialize_value(s, (jl_value_t*)m->root_blocks);
        write_int32(s->s, m->nroots_sysimg);
        jl_serialize_value(s, (jl_value_t*)m->ccallable);
        jl_serialize_value(s, (jl_value_t*)m->source);
        jl_serialize_value(s, (jl_value_t*)m->unspecialized);
        jl_serialize_value(s, (jl_value_t*)m->generator);
        jl_serialize_value(s, (jl_value_t*)m->invokes);
        jl_serialize_value(s, (jl_value_t*)m->recursion_relation);
    }
    else if (jl_is_method_instance(v)) {
        jl_method_instance_t *mi = (jl_method_instance_t*)v;
        if (jl_is_method(mi->def.value) && mi->def.method->is_for_opaque_closure) {
            jl_error("unimplemented: serialization of MethodInstances for OpaqueClosure");
        }
        write_uint8(s->s, TAG_METHOD_INSTANCE);
        int internal = 0;
        if (!jl_is_method(mi->def.method))
            internal = 1;
        else if (module_in_worklist(mi->def.method->module))
            internal = 2;
        else if (ptrhash_get(&external_mis, (void*)mi) != HT_NOTFOUND)
            internal = 3;
        write_uint8(s->s, internal);
        if (!internal) {
            // also flag this in the backref table as special
            uintptr_t *bp = (uintptr_t*)ptrhash_bp(&backref_table, v);
            assert(*bp != (uintptr_t)HT_NOTFOUND);
            *bp |= 1;
        }
        if (internal == 1)
            jl_serialize_value(s, (jl_value_t*)mi->uninferred);
        jl_serialize_value(s, (jl_value_t*)mi->specTypes);
        jl_serialize_value(s, mi->def.value);
        if (!internal)
            return;
        jl_serialize_value(s, (jl_value_t*)mi->sparam_vals);
        jl_array_t *backedges = mi->backedges;
        if (backedges) {
            // filter backedges to only contain pointers
            // to items that we will actually store (internal >= 2)
            size_t ins, i, l = jl_array_len(backedges);
            jl_method_instance_t **b_edges = (jl_method_instance_t**)jl_array_data(backedges);
            for (ins = i = 0; i < l; i++) {
                jl_method_instance_t *backedge = b_edges[i];
                if (module_in_worklist(backedge->def.method->module) || method_instance_in_queue(backedge)) {
                    b_edges[ins++] = backedge;
                }
            }
            if (ins != l)
                jl_array_del_end(backedges, l - ins);
            if (ins == 0)
                backedges = NULL;
        }
        jl_serialize_value(s, (jl_value_t*)backedges);
        jl_serialize_value(s, (jl_value_t*)NULL); //callbacks
        jl_serialize_code_instance(s, mi->cache, 1, internal);
    }
    else if (jl_is_code_instance(v)) {
        jl_serialize_code_instance(s, (jl_code_instance_t*)v, 0, 2);
    }
    else if (jl_typeis(v, jl_module_type)) {
        jl_serialize_module(s, (jl_module_t*)v);
    }
    else if (jl_typeis(v, jl_task_type)) {
        jl_error("Task cannot be serialized");
    }
    else if (jl_typeis(v, jl_opaque_closure_type)) {
        jl_error("Live opaque closures cannot be serialized");
    }
    else if (jl_typeis(v, jl_string_type)) {
        write_uint8(s->s, TAG_STRING);
        write_int32(s->s, jl_string_len(v));
        ios_write(s->s, jl_string_data(v), jl_string_len(v));
    }
    else if (jl_typeis(v, jl_int64_type)) {
        void *data = jl_data_ptr(v);
        if (*(int64_t*)data >= INT16_MIN && *(int64_t*)data <= INT16_MAX) {
            write_uint8(s->s, TAG_SHORTER_INT64);
            write_uint16(s->s, (uint16_t)*(int64_t*)data);
        }
        else if (*(int64_t*)data >= S32_MIN && *(int64_t*)data <= S32_MAX) {
            write_uint8(s->s, TAG_SHORT_INT64);
            write_int32(s->s, (int32_t)*(int64_t*)data);
        }
        else {
            write_uint8(s->s, TAG_INT64);
            write_int64(s->s, *(int64_t*)data);
        }
    }
    else if (jl_typeis(v, jl_int32_type)) {
        void *data = jl_data_ptr(v);
        if (*(int32_t*)data >= INT16_MIN && *(int32_t*)data <= INT16_MAX) {
            write_uint8(s->s, TAG_SHORT_INT32);
            write_uint16(s->s, (uint16_t)*(int32_t*)data);
        }
        else {
            write_uint8(s->s, TAG_INT32);
            write_int32(s->s, *(int32_t*)data);
        }
    }
    else if (jl_typeis(v, jl_uint8_type)) {
        write_uint8(s->s, TAG_UINT8);
        write_int8(s->s, *(int8_t*)jl_data_ptr(v));
    }
    else if (jl_is_cpointer(v) && jl_unbox_voidpointer(v) == NULL) {
        write_uint8(s->s, TAG_CNULL);
        jl_serialize_value(s, jl_typeof(v));
        return;
    }
    else if (jl_bigint_type && jl_typeis(v, jl_bigint_type)) {
        write_uint8(s->s, TAG_SHORT_GENERAL);
        write_uint8(s->s, jl_datatype_size(jl_bigint_type));
        jl_serialize_value(s, jl_bigint_type);
        jl_value_t *sizefield = jl_get_nth_field(v, 1);
        jl_serialize_value(s, sizefield);
        void *data = jl_unbox_voidpointer(jl_get_nth_field(v, 2));
        int32_t sz = jl_unbox_int32(sizefield);
        size_t nb = (sz == 0 ? 1 : (sz < 0 ? -sz : sz)) * gmp_limb_size;
        ios_write(s->s, (char*)data, nb);
    }
    else {
        jl_datatype_t *t = (jl_datatype_t*)jl_typeof(v);
        if (v == t->instance) {
            if (!type_in_worklist(t)) {
                // also flag this in the backref table as special
                // if it might not be unique (is external)
                uintptr_t *bp = (uintptr_t*)ptrhash_bp(&backref_table, v);
                assert(*bp != (uintptr_t)HT_NOTFOUND);
                *bp |= 1;
            }
            write_uint8(s->s, TAG_SINGLETON);
            jl_serialize_value(s, t);
            return;
        }
        assert(!t->instance && "detected singleton construction corruption");

        if (t == jl_typename_type) {
            void *bttag = ptrhash_get(&ser_tag, ((jl_typename_t*)t)->wrapper);
            if (bttag != HT_NOTFOUND) {
                write_uint8(s->s, TAG_BITYPENAME);
                write_uint8(s->s, (uint8_t)(intptr_t)bttag);
                return;
            }
        }
        if (t->size <= 255) {
            write_uint8(s->s, TAG_SHORT_GENERAL);
            write_uint8(s->s, t->size);
        }
        else {
            write_uint8(s->s, TAG_GENERAL);
            write_int32(s->s, t->size);
        }
        jl_serialize_value(s, t);
        if (t == jl_typename_type) {
            jl_typename_t *tn = (jl_typename_t*)v;
            int internal = module_in_worklist(tn->module);
            write_uint8(s->s, internal);
            jl_serialize_value(s, tn->module);
            jl_serialize_value(s, tn->name);
            if (internal) {
                jl_serialize_value(s, tn->names);
                jl_serialize_value(s, tn->wrapper);
                jl_serialize_value(s, tn->mt);
                ios_write(s->s, (char*)&tn->hash, sizeof(tn->hash));
                write_uint8(s->s, tn->abstract | (tn->mutabl << 1) | (tn->mayinlinealloc << 2));
                write_uint8(s->s, tn->max_methods);
                if (!tn->abstract)
                    write_uint16(s->s, tn->n_uninitialized);
                size_t nb = tn->atomicfields ? (jl_svec_len(tn->names) + 31) / 32 * sizeof(uint32_t) : 0;
                write_int32(s->s, nb);
                if (nb)
                    ios_write(s->s, (char*)tn->atomicfields, nb);
                nb = tn->constfields ? (jl_svec_len(tn->names) + 31) / 32 * sizeof(uint32_t) : 0;
                write_int32(s->s, nb);
                if (nb)
                    ios_write(s->s, (char*)tn->constfields, nb);
            }
            return;
        }

        if (jl_is_foreign_type(t)) {
            jl_error("Cannot serialize instances of foreign datatypes");
        }

        char *data = (char*)jl_data_ptr(v);
        size_t i, j, np = t->layout->npointers;
        uint32_t nf = t->layout->nfields;
        char *last = data;
        for (i = 0, j = 0; i < nf+1; i++) {
            char *ptr = data + (i < nf ? jl_field_offset(t, i) : jl_datatype_size(t));
            if (j < np) {
                char *prevptr = (char*)&((jl_value_t**)data)[jl_ptr_offset(t, j)];
                while (ptr > prevptr) {
                    // previous field contained pointers; write them and their interleaved data
                    if (prevptr > last)
                        ios_write(s->s, last, prevptr - last);
                    jl_value_t *e = *(jl_value_t**)prevptr;
                    JL_GC_PROMISE_ROOTED(e);
                    if (t->name->mutabl && e && jl_field_isptr(t, i - 1) && jl_is_cpointer(e) &&
                        jl_unbox_voidpointer(e) != (void*)-1 && jl_unbox_voidpointer(e) != NULL)
                        // reset Ptr fields to C_NULL (but keep MAP_FAILED / INVALID_HANDLE)
                        jl_serialize_cnull(s, jl_typeof(e));
                    else
                        jl_serialize_value(s, e);
                    last = prevptr + sizeof(jl_value_t*);
                    j++;
                    if (j < np)
                        prevptr = (char*)&((jl_value_t**)data)[jl_ptr_offset(t, j)];
                    else
                        break;
                }
            }
            if (i == nf)
                break;
            if (t->name->mutabl && jl_is_cpointer_type(jl_field_type(t, i)) && *(void**)ptr != (void*)-1) {
                if (ptr > last)
                    ios_write(s->s, last, ptr - last);
                char *n = NULL;
                ios_write(s->s, (char*)&n, sizeof(n));
                last = ptr + sizeof(n);
            }
        }
        char *ptr = data + jl_datatype_size(t);
        if (ptr > last)
            ios_write(s->s, last, ptr - last);
    }
}

// Used to serialize the external method instances queued in queued_method_roots (from newly_inferred)
static void serialize_htable_keys(jl_serializer_state *s, htable_t *ht, int nitems)
{
    write_int32(s->s, nitems);
    void **table = ht->table;
    size_t i, n = 0, sz = ht->size;
    for (i = 0; i < sz; i += 2) {
        if (table[i+1] != HT_NOTFOUND) {
            jl_serialize_value(s, (jl_value_t*)table[i]);
            n += 1;
        }
    }
    assert(n == nitems);
}

// Create the forward-edge map (caller => callees)
// the intent of these functions is to invert the backedges tree
// for anything that points to a method not part of the worklist
// or method instances not in the queue
//
// from MethodTables
static void jl_collect_missing_backedges_to_mod(jl_methtable_t *mt)
{
    jl_array_t *backedges = mt->backedges;
    if (backedges) {
        size_t i, l = jl_array_len(backedges);
        for (i = 1; i < l; i += 2) {
            jl_method_instance_t *caller = (jl_method_instance_t*)jl_array_ptr_ref(backedges, i);
            jl_value_t *missing_callee = jl_array_ptr_ref(backedges, i - 1);  // signature of abstract callee
            jl_array_t **edges = (jl_array_t**)ptrhash_bp(&edges_map, (void*)caller);
            if (*edges == HT_NOTFOUND)
                *edges = jl_alloc_vec_any(0);
            jl_array_ptr_1d_push(*edges, missing_callee);
        }
    }
}

// from MethodInstances
static void collect_backedges(jl_method_instance_t *callee) JL_GC_DISABLED
{
    jl_array_t *backedges = callee->backedges;
    if (backedges) {
        size_t i, l = jl_array_len(backedges);
        for (i = 0; i < l; i++) {
            jl_method_instance_t *caller = (jl_method_instance_t*)jl_array_ptr_ref(backedges, i);
            jl_array_t **edges = (jl_array_t**)ptrhash_bp(&edges_map, caller);
            if (*edges == HT_NOTFOUND)
                *edges = jl_alloc_vec_any(0);
            jl_array_ptr_1d_push(*edges, (jl_value_t*)callee);
        }
    }
}


// For functions owned by modules not on the worklist, call this on each method.
// - if the method is owned by a worklist module, add it to the list of things to be
//   fully serialized
// - otherwise (i.e., if it's an external method), check all of its specializations.
//   Collect backedges from those that are not being fully serialized.
static int jl_collect_methcache_from_mod(jl_typemap_entry_t *ml, void *closure) JL_GC_DISABLED
{
    jl_array_t *s = (jl_array_t*)closure;
    jl_method_t *m = ml->func.method;
    if (module_in_worklist(m->module)) {
        jl_array_ptr_1d_push(s, (jl_value_t*)m);
        jl_array_ptr_1d_push(s, (jl_value_t*)ml->simplesig);
    }
    else {
        jl_svec_t *specializations = m->specializations;
        size_t i, l = jl_svec_len(specializations);
        for (i = 0; i < l; i++) {
            jl_method_instance_t *callee = (jl_method_instance_t*)jl_svecref(specializations, i);
            if ((jl_value_t*)callee != jl_nothing && !method_instance_in_queue(callee))
                collect_backedges(callee);
        }
    }
    return 1;
}

static void jl_collect_methtable_from_mod(jl_array_t *s, jl_methtable_t *mt) JL_GC_DISABLED
{
    jl_typemap_visitor(mt->defs, jl_collect_methcache_from_mod, (void*)s);
}

// Collect methods of external functions defined by modules in the worklist
// "extext" = "extending external"
// Also collect relevant backedges
static void jl_collect_extext_methods_from_mod(jl_array_t *s, jl_module_t *m) JL_GC_DISABLED
{
    if (module_in_worklist(m))
        return;
    size_t i;
    void **table = m->bindings.table;
    for (i = 1; i < m->bindings.size; i += 2) {
        if (table[i] != HT_NOTFOUND) {
            jl_binding_t *b = (jl_binding_t*)table[i];
            if (b->owner == m && b->value && b->constp) {
                jl_value_t *bv = jl_unwrap_unionall(b->value);
                if (jl_is_datatype(bv)) {
                    jl_typename_t *tn = ((jl_datatype_t*)bv)->name;
                    if (tn->module == m && tn->name == b->name && tn->wrapper == b->value) {
                        jl_methtable_t *mt = tn->mt;
                        if (mt != NULL &&
                                (jl_value_t*)mt != jl_nothing &&
                                (mt != jl_type_type_mt && mt != jl_nonfunction_mt)) {
                            jl_collect_methtable_from_mod(s, mt);
                            jl_collect_missing_backedges_to_mod(mt);
                        }
                    }
                }
                else if (jl_is_module(b->value)) {
                    jl_module_t *child = (jl_module_t*)b->value;
                    if (child != m && child->parent == m && child->name == b->name) {
                        // this is the original/primary binding for the submodule
                        jl_collect_extext_methods_from_mod(s, (jl_module_t*)b->value);
                    }
                }
                else if (jl_is_mtable(b->value)) {
                    jl_methtable_t *mt = (jl_methtable_t*)b->value;
                    if (mt->module == m && mt->name == b->name) {
                        // this is probably an external method table, so let's assume so
                        // as there is no way to precisely distinguish them,
                        // and the rest of this serializer does not bother
                        // to handle any method tables specially
                        jl_collect_methtable_from_mod(s, (jl_methtable_t*)bv);
                    }
                }
            }
        }
    }
}

// flatten the backedge map reachable from caller into callees
static void jl_collect_backedges_to(jl_method_instance_t *caller, htable_t *all_callees) JL_GC_DISABLED
{
    jl_array_t **pcallees = (jl_array_t**)ptrhash_bp(&edges_map, (void*)caller),
                *callees = *pcallees;
    if (callees != HT_NOTFOUND) {
        *pcallees = (jl_array_t*) HT_NOTFOUND;
        size_t i, l = jl_array_len(callees);
        for (i = 0; i < l; i++) {
            jl_value_t *c = jl_array_ptr_ref(callees, i);
            ptrhash_put(all_callees, c, c);
            if (jl_is_method_instance(c)) {
                jl_collect_backedges_to((jl_method_instance_t*)c, all_callees);
            }
        }
    }
}

// Extract `edges` and `ext_targets` from `edges_map`
// This identifies internal->external edges in the call graph, pulling them out for special treatment.
static void jl_collect_backedges( /* edges */ jl_array_t *s, /* ext_targets */ jl_array_t *t)
{
    htable_t all_targets;         // target => tgtindex mapping
    htable_t all_callees;         // MIs called by worklist methods (eff. Set{MethodInstance})
    htable_new(&all_targets, 0);
    htable_new(&all_callees, 0);
    size_t i;
    void **table = edges_map.table;    // edges is caller => callees
    for (i = 0; i < edges_map.size; i += 2) {
        jl_method_instance_t *caller = (jl_method_instance_t*)table[i];
        jl_array_t *callees = (jl_array_t*)table[i + 1];
        if (callees != HT_NOTFOUND && (module_in_worklist(caller->def.method->module) || method_instance_in_queue(caller))) {
            size_t i, l = jl_array_len(callees);
            for (i = 0; i < l; i++) {
                jl_value_t *c = jl_array_ptr_ref(callees, i);
                ptrhash_put(&all_callees, c, c);
                if (jl_is_method_instance(c)) {
                    jl_collect_backedges_to((jl_method_instance_t*)c, &all_callees);
                }
            }
            callees = jl_alloc_array_1d(jl_array_int32_type, 0);
            void **pc = all_callees.table;
            size_t j;
            int valid = 1;
            for (j = 0; valid && j < all_callees.size; j += 2) {
                if (pc[j + 1] != HT_NOTFOUND) {
                    jl_value_t *callee = (jl_value_t*)pc[j];
                    void *target = ptrhash_get(&all_targets, (void*)callee);
                    if (target == HT_NOTFOUND) {
                        jl_method_instance_t *callee_mi = (jl_method_instance_t*)callee;
                        jl_value_t *sig;
                        if (jl_is_method_instance(callee)) {
                            sig = callee_mi->specTypes;
                        }
                        else {
                            sig = callee;
                        }
                        size_t min_valid = 0;
                        size_t max_valid = ~(size_t)0;
                        int ambig = 0;
                        jl_value_t *matches = jl_matching_methods((jl_tupletype_t*)sig, jl_nothing, -1, 0, jl_atomic_load_acquire(&jl_world_counter), &min_valid, &max_valid, &ambig);
                        if (matches == jl_false) {
                            valid = 0;
                            break;
                        }
                        size_t k;
                        for (k = 0; k < jl_array_len(matches); k++) {
                            jl_method_match_t *match = (jl_method_match_t *)jl_array_ptr_ref(matches, k);
                            jl_array_ptr_set(matches, k, match->method);
                        }
                        jl_array_ptr_1d_push(t, callee);
                        jl_array_ptr_1d_push(t, matches);
                        target = (char*)HT_NOTFOUND + jl_array_len(t) / 2;
                        ptrhash_put(&all_targets, (void*)callee, target);
                    }
                    jl_array_grow_end(callees, 1);
                    ((int32_t*)jl_array_data(callees))[jl_array_len(callees) - 1] = (char*)target - (char*)HT_NOTFOUND - 1;
                }
            }
            htable_reset(&all_callees, 100);
            if (valid) {
                jl_array_ptr_1d_push(s, (jl_value_t*)caller);
                jl_array_ptr_1d_push(s, (jl_value_t*)callees);
            }
        }
    }
    htable_free(&all_targets);
    htable_free(&all_callees);
}

// serialize information about all loaded modules
static void write_mod_list(ios_t *s, jl_array_t *a)
{
    size_t i;
    size_t len = jl_array_len(a);
    for (i = 0; i < len; i++) {
        jl_module_t *m = (jl_module_t*)jl_array_ptr_ref(a, i);
        assert(jl_is_module(m));
        if (!module_in_worklist(m)) {
            const char *modname = jl_symbol_name(m->name);
            size_t l = strlen(modname);
            write_int32(s, l);
            ios_write(s, modname, l);
            write_uint64(s, m->uuid.hi);
            write_uint64(s, m->uuid.lo);
            write_uint64(s, m->build_id);
        }
    }
    write_int32(s, 0);
}

// "magic" string and version header of .ji file
static const int JI_FORMAT_VERSION = 11;
static const char JI_MAGIC[] = "\373jli\r\n\032\n"; // based on PNG signature
static const uint16_t BOM = 0xFEFF; // byte-order marker
static void write_header(ios_t *s)
{
    ios_write(s, JI_MAGIC, strlen(JI_MAGIC));
    write_uint16(s, JI_FORMAT_VERSION);
    ios_write(s, (char *) &BOM, 2);
    write_uint8(s, sizeof(void*));
    ios_write(s, JL_BUILD_UNAME, strlen(JL_BUILD_UNAME)+1);
    ios_write(s, JL_BUILD_ARCH, strlen(JL_BUILD_ARCH)+1);
    ios_write(s, JULIA_VERSION_STRING, strlen(JULIA_VERSION_STRING)+1);
    const char *branch = jl_git_branch(), *commit = jl_git_commit();
    ios_write(s, branch, strlen(branch)+1);
    ios_write(s, commit, strlen(commit)+1);
}

// serialize information about the result of deserializing this file
static void write_work_list(ios_t *s)
{
    int i, l = jl_array_len(serializer_worklist);
    for (i = 0; i < l; i++) {
        jl_module_t *workmod = (jl_module_t*)jl_array_ptr_ref(serializer_worklist, i);
        if (workmod->parent == jl_main_module || workmod->parent == workmod) {
            size_t l = strlen(jl_symbol_name(workmod->name));
            write_int32(s, l);
            ios_write(s, jl_symbol_name(workmod->name), l);
            write_uint64(s, workmod->uuid.hi);
            write_uint64(s, workmod->uuid.lo);
            write_uint64(s, workmod->build_id);
        }
    }
    write_int32(s, 0);
}

static void write_module_path(ios_t *s, jl_module_t *depmod) JL_NOTSAFEPOINT
{
    if (depmod->parent == jl_main_module || depmod->parent == depmod)
        return;
    const char *mname = jl_symbol_name(depmod->name);
    size_t slen = strlen(mname);
    write_module_path(s, depmod->parent);
    write_int32(s, slen);
    ios_write(s, mname, slen);
}

// Cache file header
// Serialize the global Base._require_dependencies array of pathnames that
// are include dependencies. Also write Preferences and return
// the location of the srctext "pointer" in the header index.
static int64_t write_dependency_list(ios_t *s, jl_array_t **udepsp)
{
    int64_t initial_pos = 0;
    int64_t pos = 0;
    static jl_array_t *deps = NULL;
    if (!deps)
        deps = (jl_array_t*)jl_get_global(jl_base_module, jl_symbol("_require_dependencies"));

    // unique(deps) to eliminate duplicates while preserving order:
    // we preserve order so that the topmost included .jl file comes first
    static jl_value_t *unique_func = NULL;
    if (!unique_func)
        unique_func = jl_get_global(jl_base_module, jl_symbol("unique"));
    jl_value_t *uniqargs[2] = {unique_func, (jl_value_t*)deps};
    jl_task_t *ct = jl_current_task;
    size_t last_age = ct->world_age;
    ct->world_age = jl_atomic_load_acquire(&jl_world_counter);
    jl_array_t *udeps = (*udepsp = deps && unique_func ? (jl_array_t*)jl_apply(uniqargs, 2) : NULL);
    ct->world_age = last_age;

    // write a placeholder for total size so that we can quickly seek past all of the
    // dependencies if we don't need them
    initial_pos = ios_pos(s);
    write_uint64(s, 0);
    if (udeps) {
        size_t i, l = jl_array_len(udeps);
        for (i = 0; i < l; i++) {
            jl_value_t *deptuple = jl_array_ptr_ref(udeps, i);
            jl_value_t *dep = jl_fieldref(deptuple, 1);              // file abspath
            size_t slen = jl_string_len(dep);
            write_int32(s, slen);
            ios_write(s, jl_string_data(dep), slen);
            write_float64(s, jl_unbox_float64(jl_fieldref(deptuple, 2)));  // mtime
            jl_module_t *depmod = (jl_module_t*)jl_fieldref(deptuple, 0);  // evaluating module
            jl_module_t *depmod_top = depmod;
            while (depmod_top->parent != jl_main_module && depmod_top->parent != depmod_top)
                depmod_top = depmod_top->parent;
            unsigned provides = 0;
            size_t j, lj = jl_array_len(serializer_worklist);
            for (j = 0; j < lj; j++) {
                jl_module_t *workmod = (jl_module_t*)jl_array_ptr_ref(serializer_worklist, j);
                if (workmod->parent == jl_main_module || workmod->parent == workmod) {
                    ++provides;
                    if (workmod == depmod_top) {
                        write_int32(s, provides);
                        write_module_path(s, depmod);
                        break;
                    }
                }
            }
            write_int32(s, 0);
        }
        write_int32(s, 0); // terminator, for ease of reading

        // Calculate Preferences hash for current package.
        jl_value_t *prefs_hash = NULL;
        jl_value_t *prefs_list = NULL;
        JL_GC_PUSH1(&prefs_list);
        if (jl_base_module) {
            // Toplevel module is the module we're currently compiling, use it to get our preferences hash
            jl_value_t * toplevel = (jl_value_t*)jl_get_global(jl_base_module, jl_symbol("__toplevel__"));
            jl_value_t * prefs_hash_func = jl_get_global(jl_base_module, jl_symbol("get_preferences_hash"));
            jl_value_t * get_compiletime_prefs_func = jl_get_global(jl_base_module, jl_symbol("get_compiletime_preferences"));

            if (toplevel && prefs_hash_func && get_compiletime_prefs_func) {
                // Temporary invoke in newest world age
                size_t last_age = ct->world_age;
                ct->world_age = jl_atomic_load_acquire(&jl_world_counter);

                // call get_compiletime_prefs(__toplevel__)
                jl_value_t *args[3] = {get_compiletime_prefs_func, (jl_value_t*)toplevel, NULL};
                prefs_list = (jl_value_t*)jl_apply(args, 2);

                // Call get_preferences_hash(__toplevel__, prefs_list)
                args[0] = prefs_hash_func;
                args[2] = prefs_list;
                prefs_hash = (jl_value_t*)jl_apply(args, 3);

                // Reset world age to normal
                ct->world_age = last_age;
            }
        }

        // If we successfully got the preferences, write it out, otherwise write `0` for this `.ji` file.
        if (prefs_hash != NULL && prefs_list != NULL) {
            size_t i, l = jl_array_len(prefs_list);
            for (i = 0; i < l; i++) {
                jl_value_t *pref_name = jl_array_ptr_ref(prefs_list, i);
                size_t slen = jl_string_len(pref_name);
                write_int32(s, slen);
                ios_write(s, jl_string_data(pref_name), slen);
            }
            write_int32(s, 0); // terminator
            write_uint64(s, jl_unbox_uint64(prefs_hash));
        } else {
            // This is an error path, but let's at least generate a valid `.ji` file.
            // We declare an empty list of preference names, followed by a zero-hash.
            // The zero-hash is not what would be generated for an empty set of preferences,
            // and so this `.ji` file will be invalidated by a future non-erroring pass
            // through this function.
            write_int32(s, 0);
            write_uint64(s, 0);
        }
        JL_GC_POP(); // for prefs_list

        // write a dummy file position to indicate the beginning of the source-text
        pos = ios_pos(s);
        ios_seek(s, initial_pos);
        write_uint64(s, pos - initial_pos);
        ios_seek(s, pos);
        write_int64(s, 0);
    }
    return pos;
}

// --- deserialize ---

static jl_value_t *jl_deserialize_value(jl_serializer_state *s, jl_value_t **loc) JL_GC_DISABLED;

static jl_value_t *jl_deserialize_datatype(jl_serializer_state *s, int pos, jl_value_t **loc) JL_GC_DISABLED
{
    assert(pos == backref_list.len - 1 && "nothing should have been deserialized since assigning pos");
    int tag = read_uint8(s->s);
    if (tag == 6 || tag == 7) {
        jl_typename_t *name = (jl_typename_t*)jl_deserialize_value(s, NULL);
        jl_value_t *dtv = name->wrapper;
        jl_svec_t *parameters = (jl_svec_t*)jl_deserialize_value(s, NULL);
        dtv = jl_apply_type(dtv, jl_svec_data(parameters), jl_svec_len(parameters));
        backref_list.items[pos] = dtv;
        return dtv;
    }
    if (tag == 9) {
        jl_datatype_t *primarydt = (jl_datatype_t*)jl_deserialize_value(s, NULL);
        jl_value_t *dtv = jl_typeof(jl_get_kwsorter((jl_value_t*)primarydt));
        backref_list.items[pos] = dtv;
        return dtv;
    }
    if (!(tag == 0 || tag == 5 || tag == 10 || tag == 11 || tag == 12)) {
        assert(0 && "corrupt deserialization state");
        abort();
    }
    jl_datatype_t *dt = jl_new_uninitialized_datatype();
    backref_list.items[pos] = dt;
    if (loc != NULL && loc != HT_NOTFOUND)
        *loc = (jl_value_t*)dt;
    size_t size = read_int32(s->s);
    uint8_t flags = read_uint8(s->s);
    uint8_t memflags = read_uint8(s->s);
    dt->size = size;
    int has_layout = flags & 1;
    int has_instance = (flags >> 1) & 1;
    dt->hasfreetypevars = memflags & 1;
    dt->isconcretetype = (memflags >> 1) & 1;
    dt->isdispatchtuple = (memflags >> 2) & 1;
    dt->isbitstype = (memflags >> 3) & 1;
    dt->zeroinit = (memflags >> 4) & 1;
    dt->has_concrete_subtype = (memflags >> 5) & 1;
    dt->cached_by_hash = (memflags >> 6) & 1;
    dt->hash = read_int32(s->s);

    if (has_layout) {
        uint8_t layout = read_uint8(s->s);
        if (layout == 1) {
            dt->layout = ((jl_datatype_t*)jl_unwrap_unionall((jl_value_t*)jl_array_type))->layout;
        }
        else if (layout == 2) {
            dt->layout = jl_nothing_type->layout;
        }
        else if (layout == 3) {
            dt->layout = ((jl_datatype_t*)jl_unwrap_unionall((jl_value_t*)jl_pointer_type))->layout;
        }
        else {
            assert(layout == 0);
            jl_datatype_layout_t buffer;
            ios_readall(s->s, (char*)&buffer, sizeof(buffer));
            uint32_t nf = buffer.nfields;
            uint32_t np = buffer.npointers;
            uint8_t fielddesc_type = buffer.fielddesc_type;
            size_t fielddesc_size = nf > 0 ? jl_fielddesc_size(fielddesc_type) : 0;
            size_t fldsize = nf * fielddesc_size;
            if (buffer.first_ptr != -1)
                fldsize += np << fielddesc_type;
            jl_datatype_layout_t *layout = (jl_datatype_layout_t*)jl_gc_perm_alloc(
                    sizeof(jl_datatype_layout_t) + fldsize,
                    0, 4, 0);
            *layout = buffer;
            ios_readall(s->s, (char*)(layout + 1), fldsize);
            dt->layout = layout;
        }
    }

    if (tag == 10 || tag == 11 || tag == 12) {
        assert(pos > 0);
        arraylist_push(&flagref_list, loc == HT_NOTFOUND ? NULL : loc);
        arraylist_push(&flagref_list, (void*)(uintptr_t)pos);
        ptrhash_put(&uniquing_table, dt, NULL);
    }

    if (has_instance) {
        assert(dt->isconcretetype && "there shouldn't be an instance on an abstract type");
        dt->instance = jl_deserialize_value(s, &dt->instance);
        jl_gc_wb(dt, dt->instance);
    }
    dt->name = (jl_typename_t*)jl_deserialize_value(s, (jl_value_t**)&dt->name);
    jl_gc_wb(dt, dt->name);
    dt->parameters = (jl_svec_t*)jl_deserialize_value(s, (jl_value_t**)&dt->parameters);
    jl_gc_wb(dt, dt->parameters);
    dt->super = (jl_datatype_t*)jl_deserialize_value(s, (jl_value_t**)&dt->super);
    jl_gc_wb(dt, dt->super);
    dt->types = (jl_svec_t*)jl_deserialize_value(s, (jl_value_t**)&dt->types);
    if (dt->types) jl_gc_wb(dt, dt->types);

    return (jl_value_t*)dt;
}

static jl_value_t *jl_deserialize_value_svec(jl_serializer_state *s, uint8_t tag, jl_value_t **loc) JL_GC_DISABLED
{
    size_t i, len;
    if (tag == TAG_SVEC)
        len = read_uint8(s->s);
    else
        len = read_int32(s->s);
    jl_svec_t *sv = jl_alloc_svec(len);
    if (loc != NULL)
        *loc = (jl_value_t*)sv;
    arraylist_push(&backref_list, (jl_value_t*)sv);
    jl_value_t **data = jl_svec_data(sv);
    for (i = 0; i < len; i++) {
        data[i] = jl_deserialize_value(s, &data[i]);
    }
    return (jl_value_t*)sv;
}

static jl_value_t *jl_deserialize_value_symbol(jl_serializer_state *s, uint8_t tag) JL_GC_DISABLED
{
    size_t len;
    if (tag == TAG_SYMBOL)
        len = read_uint8(s->s);
    else
        len = read_int32(s->s);
    char *name = (char*)(len >= 256 ? malloc_s(len + 1) : alloca(len + 1));
    ios_readall(s->s, name, len);
    name[len] = '\0';
    jl_value_t *sym = (jl_value_t*)jl_symbol(name);
    if (len >= 256)
        free(name);
    arraylist_push(&backref_list, sym);
    return sym;
}

static jl_value_t *jl_deserialize_value_array(jl_serializer_state *s, uint8_t tag) JL_GC_DISABLED
{
    int16_t i, ndims;
    int isptr, isunion, hasptr, elsize;
    if (tag == TAG_ARRAY1D) {
        ndims = 1;
        elsize = read_uint8(s->s);
        isptr = (elsize >> 7) & 1;
        hasptr = (elsize >> 6) & 1;
        isunion = (elsize >> 5) & 1;
        elsize = elsize & 0x1f;
    }
    else {
        ndims = read_uint16(s->s);
        elsize = read_uint16(s->s);
        isptr = (elsize >> 15) & 1;
        hasptr = (elsize >> 14) & 1;
        isunion = (elsize >> 13) & 1;
        elsize = elsize & 0x1fff;
    }
    uintptr_t pos = backref_list.len;
    arraylist_push(&backref_list, NULL);
    size_t *dims = (size_t*)alloca(ndims * sizeof(size_t));
    for (i = 0; i < ndims; i++) {
        dims[i] = jl_unbox_long(jl_deserialize_value(s, NULL));
    }
    jl_array_t *a = jl_new_array_for_deserialization(
            (jl_value_t*)NULL, ndims, dims, !isptr, hasptr, isunion, elsize);
    backref_list.items[pos] = a;
    jl_value_t *aty = jl_deserialize_value(s, &jl_astaggedvalue(a)->type);
    jl_set_typeof(a, aty);
    if (a->flags.ptrarray) {
        jl_value_t **data = (jl_value_t**)jl_array_data(a);
        size_t i, numel = jl_array_len(a);
        for (i = 0; i < numel; i++) {
            data[i] = jl_deserialize_value(s, &data[i]);
            //if (data[i]) // not needed because `a` is new (gc is disabled)
            //    jl_gc_wb(a, data[i]);
        }
        assert(jl_astaggedvalue(a)->bits.gc == GC_CLEAN); // gc is disabled
    }
    else if (a->flags.hasptr) {
        size_t i, numel = jl_array_len(a);
        char *data = (char*)jl_array_data(a);
        uint16_t elsz = a->elsize;
        jl_datatype_t *et = (jl_datatype_t*)jl_tparam0(jl_typeof(a));
        size_t j, np = et->layout->npointers;
        for (i = 0; i < numel; i++) {
            char *start = data;
            for (j = 0; j < np; j++) {
                uint32_t ptr = jl_ptr_offset(et, j);
                jl_value_t **fld = &((jl_value_t**)data)[ptr];
                if ((char*)fld != start)
                    ios_readall(s->s, start, (const char*)fld - start);
                *fld = jl_deserialize_value(s, fld);
                //if (*fld) // not needed because `a` is new (gc is disabled)
                //    jl_gc_wb(a, *fld);
                start = (char*)&fld[1];
            }
            data += elsz;
            if (data != start)
                ios_readall(s->s, start, data - start);
        }
        assert(jl_astaggedvalue(a)->bits.gc == GC_CLEAN); // gc is disabled
    }
    else {
        size_t extra = jl_array_isbitsunion(a) ? jl_array_len(a) : 0;
        size_t tot = jl_array_len(a) * a->elsize + extra;
        ios_readall(s->s, (char*)jl_array_data(a), tot);
    }
    return (jl_value_t*)a;
}

static jl_value_t *jl_deserialize_value_method(jl_serializer_state *s, jl_value_t **loc) JL_GC_DISABLED
{
    jl_method_t *m =
        (jl_method_t*)jl_gc_alloc(s->ptls, sizeof(jl_method_t),
                                  jl_method_type);
    memset(m, 0, sizeof(jl_method_t));
    uintptr_t pos = backref_list.len;
    arraylist_push(&backref_list, m);
    m->sig = (jl_value_t*)jl_deserialize_value(s, (jl_value_t**)&m->sig);
    jl_gc_wb(m, m->sig);
    m->module = (jl_module_t*)jl_deserialize_value(s, (jl_value_t**)&m->module);
    jl_gc_wb(m, m->module);
    int serialization_mode = read_uint8(s->s);
    if (serialization_mode & METHOD_EXTERNAL_MT) {
        jl_module_t *mt_mod = (jl_module_t*)jl_deserialize_value(s, NULL);
        jl_sym_t *mt_name = (jl_sym_t*)jl_deserialize_value(s, NULL);
        m->external_mt = jl_get_global(mt_mod, mt_name);
        jl_gc_wb(m, m->external_mt);
        assert(jl_typeis(m->external_mt, jl_methtable_type));
    }
    else {
        m->external_mt = jl_deserialize_value(s, &m->external_mt);
        jl_gc_wb(m, m->external_mt);
    }
    if (!(serialization_mode & METHOD_INTERNAL)) {
        assert(loc != NULL && loc != HT_NOTFOUND);
        arraylist_push(&flagref_list, loc);
        arraylist_push(&flagref_list, (void*)pos);
        if (serialization_mode & METHOD_HAS_NEW_ROOTS) {
            uint64_t key = read_uint64(s->s);
            int i, nnew = read_int32(s->s);
            jl_array_t *newroots = jl_alloc_vec_any(nnew);
            jl_value_t **data = (jl_value_t**)jl_array_data(newroots);
            for (i = 0; i < nnew; i++)
                data[i] = jl_deserialize_value(s, &(data[i]));
            // Storing the new roots in `m->roots` risks losing them due to recaching
            // (which replaces pointers to `m` with ones to the "live" method).
            // Put them in separate storage so we can find them later.
            assert(ptrhash_get(&queued_method_roots, m) == HT_NOTFOUND);
            // In storing the key, on 32-bit platforms we need two slots. Might as well do this for all platforms.
            jl_svec_t *qmrval = jl_alloc_svec_uninit(3);    // GC is disabled
            jl_svec_data(qmrval)[0] = (jl_value_t*)(uintptr_t)(key & ((((uint64_t)1) << 32) - 1));          // lo bits
            jl_svec_data(qmrval)[1] = (jl_value_t*)(uintptr_t)((key >> 32) & ((((uint64_t)1) << 32) - 1));  // hi bits
            jl_svec_data(qmrval)[2] = (jl_value_t*)newroots;
            ptrhash_put(&queued_method_roots, m, qmrval);
        }
        return (jl_value_t*)m;
    }
    m->specializations = (jl_svec_t*)jl_deserialize_value(s, (jl_value_t**)&m->specializations);
    jl_gc_wb(m, m->specializations);
    jl_array_t *speckeyset = (jl_array_t*)jl_deserialize_value(s, (jl_value_t**)&m->speckeyset);
    jl_atomic_store_relaxed(&m->speckeyset, speckeyset);
    jl_gc_wb(m, speckeyset);
    m->name = (jl_sym_t*)jl_deserialize_value(s, NULL);
    jl_gc_wb(m, m->name);
    m->file = (jl_sym_t*)jl_deserialize_value(s, NULL);
    m->line = read_int32(s->s);
    m->primary_world = jl_atomic_load_acquire(&jl_world_counter);
    m->deleted_world = ~(size_t)0;
    m->called = read_int32(s->s);
    m->nargs = read_int32(s->s);
    m->nospecialize = read_int32(s->s);
    m->nkw = read_int32(s->s);
    m->isva = read_int8(s->s);
    m->pure = read_int8(s->s);
    m->is_for_opaque_closure = read_int8(s->s);
    m->constprop = read_int8(s->s);
    m->purity.bits = read_uint8(s->s);
    m->slot_syms = jl_deserialize_value(s, (jl_value_t**)&m->slot_syms);
    jl_gc_wb(m, m->slot_syms);
    m->roots = (jl_array_t*)jl_deserialize_value(s, (jl_value_t**)&m->roots);
    if (m->roots)
        jl_gc_wb(m, m->roots);
    m->root_blocks = (jl_array_t*)jl_deserialize_value(s, (jl_value_t**)&m->root_blocks);
    if (m->root_blocks)
        jl_gc_wb(m, m->root_blocks);
    m->nroots_sysimg = read_int32(s->s);
    m->ccallable = (jl_svec_t*)jl_deserialize_value(s, (jl_value_t**)&m->ccallable);
    if (m->ccallable) {
        jl_gc_wb(m, m->ccallable);
        arraylist_push(&ccallable_list, m->ccallable);
    }
    m->source = jl_deserialize_value(s, &m->source);
    if (m->source)
        jl_gc_wb(m, m->source);
    m->unspecialized = (jl_method_instance_t*)jl_deserialize_value(s, (jl_value_t**)&m->unspecialized);
    if (m->unspecialized)
        jl_gc_wb(m, m->unspecialized);
    m->generator = jl_deserialize_value(s, (jl_value_t**)&m->generator);
    if (m->generator)
        jl_gc_wb(m, m->generator);
    m->invokes = jl_deserialize_value(s, (jl_value_t**)&m->invokes);
    jl_gc_wb(m, m->invokes);
    m->recursion_relation = jl_deserialize_value(s, (jl_value_t**)&m->recursion_relation);
    if (m->recursion_relation)
        jl_gc_wb(m, m->recursion_relation);
    JL_MUTEX_INIT(&m->writelock);
    return (jl_value_t*)m;
}

static jl_value_t *jl_deserialize_value_method_instance(jl_serializer_state *s, jl_value_t **loc) JL_GC_DISABLED
{
    jl_method_instance_t *mi =
        (jl_method_instance_t*)jl_gc_alloc(s->ptls, sizeof(jl_method_instance_t),
                                       jl_method_instance_type);
    memset(mi, 0, sizeof(jl_method_instance_t));
    uintptr_t pos = backref_list.len;
    arraylist_push(&backref_list, mi);
    int internal = read_uint8(s->s);
    if (internal == 1) {
        mi->uninferred = jl_deserialize_value(s, &mi->uninferred);
        jl_gc_wb(mi, mi->uninferred);
    }
    mi->specTypes = (jl_value_t*)jl_deserialize_value(s, (jl_value_t**)&mi->specTypes);
    jl_gc_wb(mi, mi->specTypes);
    mi->def.value = jl_deserialize_value(s, &mi->def.value);
    jl_gc_wb(mi, mi->def.value);

    if (!internal) {
        assert(loc != NULL && loc != HT_NOTFOUND);
        arraylist_push(&flagref_list, loc);
        arraylist_push(&flagref_list, (void*)pos);
        return (jl_value_t*)mi;
    }

    mi->sparam_vals = (jl_svec_t*)jl_deserialize_value(s, (jl_value_t**)&mi->sparam_vals);
    jl_gc_wb(mi, mi->sparam_vals);
    mi->backedges = (jl_array_t*)jl_deserialize_value(s, (jl_value_t**)&mi->backedges);
    if (mi->backedges)
        jl_gc_wb(mi, mi->backedges);
    mi->callbacks = (jl_array_t*)jl_deserialize_value(s, (jl_value_t**)&mi->callbacks);
    if (mi->callbacks)
        jl_gc_wb(mi, mi->callbacks);
    mi->cache = (jl_code_instance_t*)jl_deserialize_value(s, (jl_value_t**)&mi->cache);
    if (mi->cache)
        jl_gc_wb(mi, mi->cache);
    return (jl_value_t*)mi;
}

static jl_value_t *jl_deserialize_value_code_instance(jl_serializer_state *s, jl_value_t **loc) JL_GC_DISABLED
{
    jl_code_instance_t *codeinst =
        (jl_code_instance_t*)jl_gc_alloc(s->ptls, sizeof(jl_code_instance_t), jl_code_instance_type);
    memset(codeinst, 0, sizeof(jl_code_instance_t));
    arraylist_push(&backref_list, codeinst);
    int flags = read_uint8(s->s);
    int validate = (flags >> 0) & 3;
    int constret = (flags >> 2) & 1;
    codeinst->ipo_purity_bits = read_uint32(s->s);
    codeinst->purity_bits = read_uint32(s->s);
    codeinst->def = (jl_method_instance_t*)jl_deserialize_value(s, (jl_value_t**)&codeinst->def);
    jl_gc_wb(codeinst, codeinst->def);
    codeinst->inferred = jl_deserialize_value(s, &codeinst->inferred);
    jl_gc_wb(codeinst, codeinst->inferred);
    codeinst->rettype_const = jl_deserialize_value(s, &codeinst->rettype_const);
    if (codeinst->rettype_const)
        jl_gc_wb(codeinst, codeinst->rettype_const);
    codeinst->rettype = jl_deserialize_value(s, &codeinst->rettype);
    jl_gc_wb(codeinst, codeinst->rettype);
    codeinst->argescapes = jl_deserialize_value(s, &codeinst->argescapes);
    jl_gc_wb(codeinst, codeinst->argescapes);
    if (constret)
        codeinst->invoke = jl_fptr_const_return;
    if ((flags >> 3) & 1)
        codeinst->precompile = 1;
    codeinst->relocatability = read_uint8(s->s);
    assert(codeinst->relocatability <= 1);
    codeinst->next = (jl_code_instance_t*)jl_deserialize_value(s, (jl_value_t**)&codeinst->next);
    jl_gc_wb(codeinst, codeinst->next);
    if (validate) {
        codeinst->min_world = jl_atomic_load_acquire(&jl_world_counter);
        ptrhash_put(&new_code_instance_validate, codeinst, (void*)(~(uintptr_t)HT_NOTFOUND));   // "HT_FOUND"
    }
    return (jl_value_t*)codeinst;
}

static jl_value_t *jl_deserialize_value_module(jl_serializer_state *s) JL_GC_DISABLED
{
    uintptr_t pos = backref_list.len;
    arraylist_push(&backref_list, NULL);
    jl_sym_t *mname = (jl_sym_t*)jl_deserialize_value(s, NULL);
    int ref_only = read_uint8(s->s);
    if (ref_only) {
        jl_value_t *m_ref;
        if (ref_only == 1)
            m_ref = jl_get_global((jl_module_t*)jl_deserialize_value(s, NULL), mname);
        else
            m_ref = jl_array_ptr_ref(s->loaded_modules_array, read_int32(s->s));
        backref_list.items[pos] = m_ref;
        return m_ref;
    }
    jl_module_t *m = jl_new_module(mname);
    backref_list.items[pos] = m;
    m->parent = (jl_module_t*)jl_deserialize_value(s, (jl_value_t**)&m->parent);
    jl_gc_wb(m, m->parent);

    while (1) {
        jl_sym_t *asname = (jl_sym_t*)jl_deserialize_value(s, NULL);
        if (asname == NULL)
            break;
        jl_binding_t *b = jl_get_binding_wr(m, asname, 1);
        b->name = (jl_sym_t*)jl_deserialize_value(s, (jl_value_t**)&b->name);
        jl_value_t *bvalue = jl_deserialize_value(s, (jl_value_t**)&b->value);
        *(jl_value_t**)&b->value = bvalue;
        if (bvalue != NULL) jl_gc_wb(m, bvalue);
        jl_value_t *bglobalref = jl_deserialize_value(s, (jl_value_t**)&b->globalref);
        *(jl_value_t**)&b->globalref = bglobalref;
        if (bglobalref != NULL) jl_gc_wb(m, bglobalref);
        b->owner = (jl_module_t*)jl_deserialize_value(s, (jl_value_t**)&b->owner);
        if (b->owner != NULL) jl_gc_wb(m, b->owner);
        jl_value_t *bty = jl_deserialize_value(s, (jl_value_t**)&b->ty);
        *(jl_value_t**)&b->ty = bty;
        int8_t flags = read_int8(s->s);
        b->deprecated = (flags>>3) & 1;
        b->constp = (flags>>2) & 1;
        b->exportp = (flags>>1) & 1;
        b->imported = (flags) & 1;
    }
    size_t i = m->usings.len;
    size_t ni = read_int32(s->s);
    arraylist_grow(&m->usings, ni);
    ni += i;
    while (i < ni) {
        m->usings.items[i] = jl_deserialize_value(s, (jl_value_t**)&m->usings.items[i]);
        i++;
    }
    m->istopmod = read_uint8(s->s);
    m->uuid.hi = read_uint64(s->s);
    m->uuid.lo = read_uint64(s->s);
    m->build_id = read_uint64(s->s);
    m->counter = read_int32(s->s);
    m->nospecialize = read_int32(s->s);
    m->optlevel = read_int8(s->s);
    m->compile = read_int8(s->s);
    m->infer = read_int8(s->s);
    m->max_methods = read_int8(s->s);
    m->primary_world = jl_atomic_load_acquire(&jl_world_counter);
    return (jl_value_t*)m;
}

static jl_value_t *jl_deserialize_value_singleton(jl_serializer_state *s, jl_value_t **loc) JL_GC_DISABLED
{
    jl_value_t *v = (jl_value_t*)jl_gc_alloc(s->ptls, 0, NULL);
    uintptr_t pos = backref_list.len;
    arraylist_push(&backref_list, (void*)v);
    // TODO: optimize the case where the value can easily be obtained
    // from an external module (tag == 6) as dt->instance
    assert(loc != HT_NOTFOUND);
    // if loc == NULL, then the caller can't provide the address where the instance will be
    // stored. this happens if a field might store a 0-size value, but the field itself is
    // not 0 size, e.g. `::Union{Int,Nothing}`
    if (loc != NULL) {
        arraylist_push(&flagref_list, loc);
        arraylist_push(&flagref_list, (void*)pos);
    }
    jl_datatype_t *dt = (jl_datatype_t*)jl_deserialize_value(s, (jl_value_t**)HT_NOTFOUND); // no loc, since if dt is replaced, then dt->instance would be also
    jl_set_typeof(v, dt);
    if (dt->instance == NULL)
        return v;
    return dt->instance;
}

static void jl_deserialize_struct(jl_serializer_state *s, jl_value_t *v) JL_GC_DISABLED
{
    jl_datatype_t *dt = (jl_datatype_t*)jl_typeof(v);
    char *data = (char*)jl_data_ptr(v);
    size_t i, np = dt->layout->npointers;
    char *start = data;
    for (i = 0; i < np; i++) {
        uint32_t ptr = jl_ptr_offset(dt, i);
        jl_value_t **fld = &((jl_value_t**)data)[ptr];
        if ((char*)fld != start)
            ios_readall(s->s, start, (const char*)fld - start);
        *fld = jl_deserialize_value(s, fld);
        //if (*fld)// a is new (gc is disabled)
        //    jl_gc_wb(a, *fld);
        start = (char*)&fld[1];
    }
    data += jl_datatype_size(dt);
    if (data != start)
        ios_readall(s->s, start, data - start);
    if (dt == jl_typemap_entry_type) {
        jl_typemap_entry_t *entry = (jl_typemap_entry_t*)v;
        if (entry->max_world == ~(size_t)0) {
            if (entry->min_world > 1) {
                // update world validity to reflect current state of the counter
                entry->min_world = jl_atomic_load_acquire(&jl_world_counter);
            }
        }
        else {
            // garbage entry - delete it :(
            entry->min_world = 1;
            entry->max_world = 0;
        }
    }
}

static jl_value_t *jl_deserialize_value_any(jl_serializer_state *s, uint8_t tag, jl_value_t **loc) JL_GC_DISABLED
{
    int32_t sz = (tag == TAG_SHORT_GENERAL ? read_uint8(s->s) : read_int32(s->s));
    jl_value_t *v = jl_gc_alloc(s->ptls, sz, NULL);
    jl_set_typeof(v, (void*)(intptr_t)0x50);
    uintptr_t pos = backref_list.len;
    arraylist_push(&backref_list, v);
    jl_datatype_t *dt = (jl_datatype_t*)jl_deserialize_value(s, &jl_astaggedvalue(v)->type);
    assert(sz != 0 || loc);
    if (dt == jl_typename_type) {
        int internal = read_uint8(s->s);
        jl_typename_t *tn;
        if (internal) {
            tn = (jl_typename_t*)jl_gc_alloc(
                    s->ptls, sizeof(jl_typename_t), jl_typename_type);
            memset(tn, 0, sizeof(jl_typename_t));
            tn->cache = jl_emptysvec; // the cache is refilled later (tag 5)
            tn->linearcache = jl_emptysvec; // the cache is refilled later (tag 5)
            backref_list.items[pos] = tn;
        }
        jl_module_t *m = (jl_module_t*)jl_deserialize_value(s, NULL);
        jl_sym_t *sym = (jl_sym_t*)jl_deserialize_value(s, NULL);
        if (internal) {
            tn->module = m;
            tn->name = sym;
            tn->names = (jl_svec_t*)jl_deserialize_value(s, (jl_value_t**)&tn->names);
            jl_gc_wb(tn, tn->names);
            tn->wrapper = jl_deserialize_value(s, &tn->wrapper);
            jl_gc_wb(tn, tn->wrapper);
            tn->mt = (jl_methtable_t*)jl_deserialize_value(s, (jl_value_t**)&tn->mt);
            jl_gc_wb(tn, tn->mt);
            ios_read(s->s, (char*)&tn->hash, sizeof(tn->hash));
            int8_t flags = read_int8(s->s);
            tn->abstract = flags & 1;
            tn->mutabl = (flags>>1) & 1;
            tn->mayinlinealloc = (flags>>2) & 1;
            tn->max_methods = read_uint8(s->s);
            if (tn->abstract)
                tn->n_uninitialized = 0;
            else
                tn->n_uninitialized = read_uint16(s->s);
            size_t nfields = read_int32(s->s);
            if (nfields) {
                tn->atomicfields = (uint32_t*)malloc(nfields);
                ios_read(s->s, (char*)tn->atomicfields, nfields);
            }
            nfields = read_int32(s->s);
            if (nfields) {
                tn->constfields = (uint32_t*)malloc(nfields);
                ios_read(s->s, (char*)tn->constfields, nfields);
            }
        }
        else {
            jl_datatype_t *dt = (jl_datatype_t*)jl_unwrap_unionall(jl_get_global(m, sym));
            assert(jl_is_datatype(dt));
            tn = dt->name;
            backref_list.items[pos] = tn;
        }
        return (jl_value_t*)tn;
    }
    jl_set_typeof(v, dt);
    if ((jl_value_t*)dt == jl_bigint_type) {
        jl_value_t *sizefield = jl_deserialize_value(s, NULL);
        int32_t sz = jl_unbox_int32(sizefield);
        int32_t nw = (sz == 0 ? 1 : (sz < 0 ? -sz : sz));
        size_t nb = nw * gmp_limb_size;
        void *buf = jl_gc_counted_malloc(nb);
        if (buf == NULL)
            jl_throw(jl_memory_exception);
        ios_readall(s->s, (char*)buf, nb);
        jl_set_nth_field(v, 0, jl_box_int32(nw));
        jl_set_nth_field(v, 1, sizefield);
        jl_set_nth_field(v, 2, jl_box_voidpointer(buf));
    }
    else {
        jl_deserialize_struct(s, v);
    }
    return v;
}

static jl_value_t *jl_deserialize_value(jl_serializer_state *s, jl_value_t **loc) JL_GC_DISABLED
{
    assert(!ios_eof(s->s));
    jl_value_t *v;
    size_t n;
    uintptr_t pos;
    uint8_t tag = read_uint8(s->s);
    if (tag > LAST_TAG)
        return deser_tag[tag];
    switch (tag) {
    case TAG_NULL: return NULL;
    case 0:
        tag = read_uint8(s->s);
        return deser_tag[tag];
    case TAG_BACKREF: JL_FALLTHROUGH; case TAG_SHORT_BACKREF: ;
        uintptr_t offs = (tag == TAG_BACKREF) ? read_int32(s->s) : read_uint16(s->s);
        int isflagref = 0;
        isflagref = !!(offs & 1);
        offs >>= 1;
        // assert(offs >= 0); // offs is unsigned so this is always true
        assert(offs < backref_list.len);
        jl_value_t *bp = (jl_value_t*)backref_list.items[offs];
        assert(bp);
        if (isflagref && loc != HT_NOTFOUND) {
            if (loc != NULL) {
                // as in jl_deserialize_value_singleton, the caller won't have a place to
                // store this reference given a field type like Union{Int,Nothing}
                arraylist_push(&flagref_list, loc);
                arraylist_push(&flagref_list, (void*)(uintptr_t)-1);
            }
        }
        return (jl_value_t*)bp;
    case TAG_SVEC: JL_FALLTHROUGH; case TAG_LONG_SVEC:
        return jl_deserialize_value_svec(s, tag, loc);
    case TAG_COMMONSYM:
        return deser_symbols[read_uint8(s->s)];
    case TAG_SYMBOL: JL_FALLTHROUGH; case TAG_LONG_SYMBOL:
        return jl_deserialize_value_symbol(s, tag);
    case TAG_ARRAY: JL_FALLTHROUGH; case TAG_ARRAY1D:
        return jl_deserialize_value_array(s, tag);
    case TAG_UNIONALL:
        pos = backref_list.len;
        arraylist_push(&backref_list, NULL);
        if (read_uint8(s->s)) {
            jl_module_t *m = (jl_module_t*)jl_deserialize_value(s, NULL);
            jl_sym_t *sym = (jl_sym_t*)jl_deserialize_value(s, NULL);
            jl_value_t *v = jl_get_global(m, sym);
            assert(jl_is_unionall(v));
            backref_list.items[pos] = v;
            return v;
        }
        v = jl_gc_alloc(s->ptls, sizeof(jl_unionall_t), jl_unionall_type);
        backref_list.items[pos] = v;
        ((jl_unionall_t*)v)->var = (jl_tvar_t*)jl_deserialize_value(s, (jl_value_t**)&((jl_unionall_t*)v)->var);
        jl_gc_wb(v, ((jl_unionall_t*)v)->var);
        ((jl_unionall_t*)v)->body = jl_deserialize_value(s, &((jl_unionall_t*)v)->body);
        jl_gc_wb(v, ((jl_unionall_t*)v)->body);
        return v;
    case TAG_TVAR:
        v = jl_gc_alloc(s->ptls, sizeof(jl_tvar_t), jl_tvar_type);
        jl_tvar_t *tv = (jl_tvar_t*)v;
        arraylist_push(&backref_list, tv);
        tv->name = (jl_sym_t*)jl_deserialize_value(s, NULL);
        jl_gc_wb(tv, tv->name);
        tv->lb = jl_deserialize_value(s, &tv->lb);
        jl_gc_wb(tv, tv->lb);
        tv->ub = jl_deserialize_value(s, &tv->ub);
        jl_gc_wb(tv, tv->ub);
        return (jl_value_t*)tv;
    case TAG_METHOD:
        return jl_deserialize_value_method(s, loc);
    case TAG_METHOD_INSTANCE:
        return jl_deserialize_value_method_instance(s, loc);
    case TAG_CODE_INSTANCE:
        return jl_deserialize_value_code_instance(s, loc);
    case TAG_MODULE:
        return jl_deserialize_value_module(s);
    case TAG_SHORTER_INT64:
        v = jl_box_int64((int16_t)read_uint16(s->s));
        arraylist_push(&backref_list, v);
        return v;
    case TAG_SHORT_INT64:
        v = jl_box_int64(read_int32(s->s));
        arraylist_push(&backref_list, v);
        return v;
    case TAG_INT64:
        v = jl_box_int64((int64_t)read_uint64(s->s));
        arraylist_push(&backref_list, v);
        return v;
    case TAG_SHORT_INT32:
        v = jl_box_int32((int16_t)read_uint16(s->s));
        arraylist_push(&backref_list, v);
        return v;
    case TAG_INT32:
        v = jl_box_int32(read_int32(s->s));
        arraylist_push(&backref_list, v);
        return v;
    case TAG_UINT8:
        return jl_box_uint8(read_uint8(s->s));
    case TAG_SINGLETON:
        return jl_deserialize_value_singleton(s, loc);
    case TAG_CORE:
        return (jl_value_t*)jl_core_module;
    case TAG_BASE:
        return (jl_value_t*)jl_base_module;
    case TAG_CNULL:
        v = jl_gc_alloc(s->ptls, sizeof(void*), NULL);
        jl_set_typeof(v, (void*)(intptr_t)0x50);
        *(void**)v = NULL;
        uintptr_t pos = backref_list.len;
        arraylist_push(&backref_list, v);
        jl_set_typeof(v, jl_deserialize_value(s, &jl_astaggedvalue(v)->type));
        return v;
    case TAG_BITYPENAME:
        v = deser_tag[read_uint8(s->s)];
        return (jl_value_t*)((jl_datatype_t*)jl_unwrap_unionall(v))->name;
    case TAG_STRING:
        n = read_int32(s->s);
        v = jl_alloc_string(n);
        arraylist_push(&backref_list, v);
        ios_readall(s->s, jl_string_data(v), n);
        return v;
    case TAG_DATATYPE:
        pos = backref_list.len;
        arraylist_push(&backref_list, NULL);
        return jl_deserialize_datatype(s, pos, loc);
    default:
        assert(tag == TAG_GENERAL || tag == TAG_SHORT_GENERAL);
        return jl_deserialize_value_any(s, tag, loc);
    }
}

// Add methods to external (non-worklist-owned) functions
static void jl_insert_methods(jl_array_t *list)
{
    size_t i, l = jl_array_len(list);
    for (i = 0; i < l; i += 2) {
        jl_method_t *meth = (jl_method_t*)jl_array_ptr_ref(list, i);
        assert(jl_is_method(meth));
        assert(!meth->is_for_opaque_closure);
        jl_tupletype_t *simpletype = (jl_tupletype_t*)jl_array_ptr_ref(list, i + 1);
        jl_methtable_t *mt = jl_method_get_table(meth);
        assert((jl_value_t*)mt != jl_nothing);
        jl_method_table_insert(mt, meth, simpletype);
    }
}

void remove_code_instance_from_validation(jl_code_instance_t *codeinst)
{
    ptrhash_remove(&new_code_instance_validate, codeinst);
}

static void jl_insert_method_instances(jl_array_t *list)
{
    size_t i, l = jl_array_len(list);
    // Validate the MethodInstances
    jl_array_t *valids = jl_alloc_array_1d(jl_array_uint8_type, l);
    memset(jl_array_data(valids), 1, l);
    size_t world = jl_atomic_load_acquire(&jl_world_counter);
    for (i = 0; i < l; i++) {
        jl_method_instance_t *mi = (jl_method_instance_t*)jl_array_ptr_ref(list, i);
        assert(jl_is_method_instance(mi));
        if (jl_is_method(mi->def.method)) {
            // Is this still the method we'd be calling?
            jl_methtable_t *mt = jl_method_table_for(mi->specTypes);
            struct jl_typemap_assoc search = {(jl_value_t*)mi->specTypes, world, NULL, 0, ~(size_t)0};
            jl_typemap_entry_t *entry = jl_typemap_assoc_by_type(mt->defs, &search, /*offs*/0, /*subtype*/1);
            if (entry) {
                jl_value_t *mworld = entry->func.value;
                if (jl_is_method(mworld) && mi->def.method != (jl_method_t*)mworld && jl_type_morespecific(((jl_method_t*)mworld)->sig, mi->def.method->sig)) {
                    jl_array_uint8_set(valids, i, 0);
                    invalidate_backedges(&remove_code_instance_from_validation, mi, world, "jl_insert_method_instance");
                    // The codeinst of this mi haven't yet been removed
                    jl_code_instance_t *codeinst = mi->cache;
                    while (codeinst) {
                        remove_code_instance_from_validation(codeinst);
                        codeinst = codeinst->next;
                    }
                    if (_jl_debug_method_invalidation) {
                        jl_array_ptr_1d_push(_jl_debug_method_invalidation, mworld);
                        jl_array_ptr_1d_push(_jl_debug_method_invalidation, jl_cstr_to_string("jl_method_table_insert")); // GC disabled
                    }
                }
            }
        }
    }
    // While it's tempting to just remove the invalidated MIs altogether,
    // this hurts the ability of SnoopCompile to diagnose problems.
    for (i = 0; i < l; i++) {
        jl_method_instance_t *mi = (jl_method_instance_t*)jl_array_ptr_ref(list, i);
        jl_method_instance_t *milive = jl_specializations_get_or_insert(mi);
        ptrhash_put(&uniquing_table, mi, milive);  // store the association for the 2nd pass
    }
    // We may need to fix up the backedges for the ones that didn't "go live"
    for (i = 0; i < l; i++) {
        jl_method_instance_t *mi = (jl_method_instance_t*)jl_array_ptr_ref(list, i);
        jl_method_instance_t *milive = (jl_method_instance_t*)ptrhash_get(&uniquing_table, mi);
        if (milive != mi) {
            // A previously-loaded module compiled this method, so the one we deserialized will be dropped.
            // But make sure the backedges are copied over.
            if (mi->backedges) {
                if (!milive->backedges) {
                    // Copy all the backedges (after looking up the live ones)
                    size_t j, n = jl_array_len(mi->backedges);
                    milive->backedges = jl_alloc_vec_any(n);
                    jl_gc_wb(milive, milive->backedges);
                    for (j = 0; j < n; j++) {
                        jl_method_instance_t *be = (jl_method_instance_t*)jl_array_ptr_ref(mi->backedges, j);
                        jl_method_instance_t *belive = (jl_method_instance_t*)ptrhash_get(&uniquing_table, be);
                        if (belive == HT_NOTFOUND)
                            belive = be;
                        jl_array_ptr_set(milive->backedges, j, belive);
                    }
                } else {
                    // Copy the missing backedges (this is an O(N^2) algorithm, but many methods have few MethodInstances)
                    size_t j, k, n = jl_array_len(mi->backedges), nlive = jl_array_len(milive->backedges);
                    for (j = 0; j < n; j++) {
                        jl_method_instance_t *be = (jl_method_instance_t*)jl_array_ptr_ref(mi->backedges, j);
                        jl_method_instance_t *belive = (jl_method_instance_t*)ptrhash_get(&uniquing_table, be);
                        if (belive == HT_NOTFOUND)
                            belive = be;
                        int found = 0;
                        for (k = 0; k < nlive; k++) {
                            if (belive == (jl_method_instance_t*)jl_array_ptr_ref(milive->backedges, k)) {
                                found = 1;
                                break;
                            }
                        }
                        if (!found)
                            jl_array_ptr_1d_push(milive->backedges, (jl_value_t*)belive);
                    }
                }
            }
            // Additionally, if we have CodeInstance(s) and the running CodeInstance is world-limited, transfer it
            if (mi->cache && jl_array_uint8_ref(valids, i)) {
                if (!milive->cache || milive->cache->max_world < ~(size_t)0) {
                    jl_code_instance_t *cilive = milive->cache, *ci;
                    milive->cache = mi->cache;
                    jl_gc_wb(milive, milive->cache);
                    ci = mi->cache;
                    ci->def = milive;
                    while (ci->next) {
                        ci = ci->next;
                        ci->def = milive;
                    }
                    ci->next = cilive;
                    jl_gc_wb(ci, ci->next);
                }
            }
        }
    }
}

// verify that these edges intersect with the same methods as before
static void jl_verify_edges(jl_array_t *targets, jl_array_t **pvalids)
{
    size_t i, l = jl_array_len(targets) / 2;
    jl_array_t *valids = jl_alloc_array_1d(jl_array_uint8_type, l);
    memset(jl_array_data(valids), 1, l);
    jl_value_t *loctag = NULL;
    JL_GC_PUSH1(&loctag);
    *pvalids = valids;
    for (i = 0; i < l; i++) {
        jl_value_t *callee = jl_array_ptr_ref(targets, i * 2);
        jl_method_instance_t *callee_mi = (jl_method_instance_t*)callee;
        jl_value_t *sig;
        if (jl_is_method_instance(callee)) {
            sig = callee_mi->specTypes;
        }
        else {
            sig = callee;
        }
        jl_array_t *expected = (jl_array_t*)jl_array_ptr_ref(targets, i * 2 + 1);
        assert(jl_is_array(expected));
        int valid = 1;
        size_t min_valid = 0;
        size_t max_valid = ~(size_t)0;
        int ambig = 0;
        // TODO: possibly need to included ambiguities too (for the optimizer correctness)?
        jl_value_t *matches = jl_matching_methods((jl_tupletype_t*)sig, jl_nothing, -1, 0, jl_atomic_load_acquire(&jl_world_counter), &min_valid, &max_valid, &ambig);
        if (matches == jl_false || jl_array_len(matches) != jl_array_len(expected)) {
            valid = 0;
        }
        else {
            size_t j, k, l = jl_array_len(expected);
            for (k = 0; k < jl_array_len(matches); k++) {
                jl_method_match_t *match = (jl_method_match_t*)jl_array_ptr_ref(matches, k);
                jl_method_t *m = match->method;
                for (j = 0; j < l; j++) {
                    if (m == (jl_method_t*)jl_array_ptr_ref(expected, j))
                        break;
                }
                if (j == l) {
                    // intersection has a new method or a method was
                    // deleted--this is now probably no good, just invalidate
                    // everything about it now
                    valid = 0;
                    break;
                }
            }
        }
        jl_array_uint8_set(valids, i, valid);
        if (!valid && _jl_debug_method_invalidation) {
            jl_array_ptr_1d_push(_jl_debug_method_invalidation, (jl_value_t*)callee);
            loctag = jl_cstr_to_string("insert_backedges_callee");
            jl_array_ptr_1d_push(_jl_debug_method_invalidation, loctag);
        }
    }
    JL_GC_POP();
}

// Restore backedges to external targets
// `targets` is [callee1, matches1, ...], the global set of non-worklist callees of worklist-owned methods.
// `list` = [caller1, targets_indexes1, ...], the list of worklist-owned methods calling external methods.
static void jl_insert_backedges(jl_array_t *list, jl_array_t *targets)
{
    // map(enable, ((list[i] => targets[list[i + 1] .* 2]) for i in 1:2:length(list) if all(valids[list[i + 1]])))
    size_t i, l = jl_array_len(list);
    jl_array_t *valids = NULL;
    jl_value_t *loctag = NULL;
    JL_GC_PUSH2(&valids, &loctag);
    jl_verify_edges(targets, &valids);
    for (i = 0; i < l; i += 2) {
        jl_method_instance_t *caller = (jl_method_instance_t*)jl_array_ptr_ref(list, i);
        assert(jl_is_method_instance(caller) && jl_is_method(caller->def.method));
        jl_array_t *idxs_array = (jl_array_t*)jl_array_ptr_ref(list, i + 1);
        assert(jl_isa((jl_value_t*)idxs_array, jl_array_int32_type));
        int32_t *idxs = (int32_t*)jl_array_data(idxs_array);
        int valid = 1;
        size_t j;
        for (j = 0; valid && j < jl_array_len(idxs_array); j++) {
            int32_t idx = idxs[j];
            valid = jl_array_uint8_ref(valids, idx);
        }
        if (valid) {
            // if this callee is still valid, add all the backedges
            for (j = 0; j < jl_array_len(idxs_array); j++) {
                int32_t idx = idxs[j];
                jl_value_t *callee = jl_array_ptr_ref(targets, idx * 2);
                if (jl_is_method_instance(callee)) {
                    jl_method_instance_add_backedge((jl_method_instance_t*)callee, caller);
                }
                else {
                    jl_methtable_t *mt = jl_method_table_for(callee);
                    // FIXME: rarely, `callee` has an unexpected `Union` signature,
                    // see https://github.com/JuliaLang/julia/pull/43990#issuecomment-1030329344
                    // Fix the issue and turn this back into an `assert((jl_value_t*)mt != jl_nothing)`
                    // This workaround exposes us to (rare) 265-violations.
                    if ((jl_value_t*)mt != jl_nothing)
                        jl_method_table_add_backedge(mt, callee, (jl_value_t*)caller);
                }
            }
            // then enable it
            jl_code_instance_t *codeinst = caller->cache;
            while (codeinst) {
                if (ptrhash_get(&new_code_instance_validate, codeinst) != HT_NOTFOUND && codeinst->min_world > 0)
                    codeinst->max_world = ~(size_t)0;
                ptrhash_remove(&new_code_instance_validate, codeinst);  // mark it as handled
                codeinst = jl_atomic_load_relaxed(&codeinst->next);
            }
        }
        else {
            jl_code_instance_t *codeinst = caller->cache;
            while (codeinst) {
                ptrhash_remove(&new_code_instance_validate, codeinst);  // should be left invalid
                codeinst = jl_atomic_load_relaxed(&codeinst->next);
            }
            if (_jl_debug_method_invalidation) {
                jl_array_ptr_1d_push(_jl_debug_method_invalidation, (jl_value_t*)caller);
                loctag = jl_cstr_to_string("insert_backedges");
                jl_array_ptr_1d_push(_jl_debug_method_invalidation, loctag);
            }
        }
    }
    JL_GC_POP();
}

static void validate_new_code_instances(void)
{
    size_t i;
    for (i = 0; i < new_code_instance_validate.size; i += 2) {
        if (new_code_instance_validate.table[i+1] != HT_NOTFOUND) {
            ((jl_code_instance_t*)new_code_instance_validate.table[i])->max_world = ~(size_t)0;
        }
    }
}

static jl_value_t *read_verify_mod_list(ios_t *s, jl_array_t *mod_list)
{
    if (!jl_main_module->build_id) {
        return jl_get_exceptionf(jl_errorexception_type,
                "Main module uuid state is invalid for module deserialization.");
    }
    size_t i, l = jl_array_len(mod_list);
    for (i = 0; ; i++) {
        size_t len = read_int32(s);
        if (len == 0 && i == l)
            return NULL; // success
        if (len == 0 || i == l)
            return jl_get_exceptionf(jl_errorexception_type, "Wrong number of entries in module list.");
        char *name = (char*)alloca(len + 1);
        ios_readall(s, name, len);
        name[len] = '\0';
        jl_uuid_t uuid;
        uuid.hi = read_uint64(s);
        uuid.lo = read_uint64(s);
        uint64_t build_id = read_uint64(s);
        jl_sym_t *sym = _jl_symbol(name, len);
        jl_module_t *m = (jl_module_t*)jl_array_ptr_ref(mod_list, i);
        if (!m || !jl_is_module(m) || m->uuid.hi != uuid.hi || m->uuid.lo != uuid.lo || m->name != sym || m->build_id != build_id) {
            return jl_get_exceptionf(jl_errorexception_type,
                "Invalid input in module list: expected %s.", name);
        }
    }
}

static int readstr_verify(ios_t *s, const char *str)
{
    size_t i, len = strlen(str);
    for (i = 0; i < len; ++i)
        if ((char)read_uint8(s) != str[i])
            return 0;
    return 1;
}

JL_DLLEXPORT int jl_read_verify_header(ios_t *s)
{
    uint16_t bom;
    return (readstr_verify(s, JI_MAGIC) &&
            read_uint16(s) == JI_FORMAT_VERSION &&
            ios_read(s, (char *) &bom, 2) == 2 && bom == BOM &&
            read_uint8(s) == sizeof(void*) &&
            readstr_verify(s, JL_BUILD_UNAME) && !read_uint8(s) &&
            readstr_verify(s, JL_BUILD_ARCH) && !read_uint8(s) &&
            readstr_verify(s, JULIA_VERSION_STRING) && !read_uint8(s) &&
            readstr_verify(s, jl_git_branch()) && !read_uint8(s) &&
            readstr_verify(s, jl_git_commit()) && !read_uint8(s));
}

static void jl_finalize_serializer(jl_serializer_state *s)
{
    size_t i, l;
    // save module initialization order
    if (jl_module_init_order != NULL) {
        l = jl_array_len(jl_module_init_order);
        for (i = 0; i < l; i++) {
            // verify that all these modules were saved
            assert(ptrhash_get(&backref_table, jl_array_ptr_ref(jl_module_init_order, i)) != HT_NOTFOUND);
        }
    }
    jl_serialize_value(s, jl_module_init_order);

    // record list of reinitialization functions
    l = reinit_list.len;
    for (i = 0; i < l; i += 2) {
        write_int32(s->s, (int)((uintptr_t) reinit_list.items[i]));
        write_int32(s->s, (int)((uintptr_t) reinit_list.items[i+1]));
    }
    write_int32(s->s, -1);
}

static void jl_reinit_item(jl_value_t *v, int how, arraylist_t *tracee_list)
{
    JL_TRY {
        switch (how) {
            case 1: { // rehash IdDict
                jl_array_t **a = (jl_array_t**)v;
                // Assume *a don't need a write barrier
                *a = jl_idtable_rehash(*a, jl_array_len(*a));
                jl_gc_wb(v, *a);
                break;
            }
            case 2: { // reinsert module v into parent (const)
                jl_module_t *mod = (jl_module_t*)v;
                if (mod->parent == mod) // top level modules handled by loader
                    break;
                jl_binding_t *b = jl_get_binding_wr(mod->parent, mod->name, 1); // this can throw
                jl_declare_constant(b); // this can also throw
                if (b->value != NULL) {
                    if (!jl_is_module(b->value)) {
                        jl_errorf("Invalid redefinition of constant %s.",
                                  jl_symbol_name(mod->name)); // this also throws
                    }
                    if (jl_generating_output() && jl_options.incremental) {
                        jl_errorf("Cannot replace module %s during incremental precompile.", jl_symbol_name(mod->name));
                    }
                    jl_printf(JL_STDERR, "WARNING: replacing module %s.\n", jl_symbol_name(mod->name));
                }
                b->value = v;
                jl_gc_wb_binding(b, v);
                break;
            }
            case 3: { // rehash MethodTable
                jl_methtable_t *mt = (jl_methtable_t*)v;
                if (tracee_list)
                    arraylist_push(tracee_list, mt);
                break;
            }
            default:
                assert(0 && "corrupt deserialization state");
                abort();
        }
    }
    JL_CATCH {
        jl_printf((JL_STREAM*)STDERR_FILENO, "WARNING: error while reinitializing value ");
        jl_static_show((JL_STREAM*)STDERR_FILENO, v);
        jl_printf((JL_STREAM*)STDERR_FILENO, ":\n");
        jl_static_show((JL_STREAM*)STDERR_FILENO, jl_current_exception());
        jl_printf((JL_STREAM*)STDERR_FILENO, "\n");
        jlbacktrace(); // written to STDERR_FILENO
    }
}

static jl_array_t *jl_finalize_deserializer(jl_serializer_state *s, arraylist_t *tracee_list)
{
    jl_array_t *init_order = (jl_array_t*)jl_deserialize_value(s, NULL);

    // run reinitialization functions
    int pos = read_int32(s->s);
    while (pos != -1) {
        jl_reinit_item((jl_value_t*)backref_list.items[pos], read_int32(s->s), tracee_list);
        pos = read_int32(s->s);
    }
    return init_order;
}

JL_DLLEXPORT void jl_init_restored_modules(jl_array_t *init_order)
{
    int i, l = jl_array_len(init_order);
    for (i = 0; i < l; i++) {
        jl_value_t *mod = jl_array_ptr_ref(init_order, i);
        if (!jl_generating_output() || jl_options.incremental) {
            jl_module_run_initializer((jl_module_t*)mod);
        }
        else {
            if (jl_module_init_order == NULL)
                jl_module_init_order = jl_alloc_vec_any(0);
            jl_array_ptr_1d_push(jl_module_init_order, mod);
        }
    }
}


// --- entry points ---

// Register all newly-inferred MethodInstances
// This gets called as the final step of Base.include_package_for_output
JL_DLLEXPORT void jl_set_newly_inferred(jl_value_t* _newly_inferred)
{
    assert(_newly_inferred == NULL || jl_is_array(_newly_inferred));
    newly_inferred = (jl_array_t*) _newly_inferred;
}

// Serialize the modules in `worklist` to file `fname`
JL_DLLEXPORT int jl_save_incremental(const char *fname, jl_array_t *worklist)
{
    JL_TIMING(SAVE_MODULE);
    ios_t f;
    jl_array_t *mod_array = NULL, *udeps = NULL;
    if (ios_file(&f, fname, 1, 1, 1, 1) == NULL) {
        jl_printf(JL_STDERR, "Cannot open cache file \"%s\" for writing.\n", fname);
        return 1;
    }
    JL_GC_PUSH2(&mod_array, &udeps);
    mod_array = jl_get_loaded_modules();  // __toplevel__ modules loaded in this session (from Base.loaded_modules_array)
    assert(jl_precompile_toplevel_module == NULL);
    jl_precompile_toplevel_module = (jl_module_t*)jl_array_ptr_ref(worklist, jl_array_len(worklist)-1);

    serializer_worklist = worklist;
    write_header(&f);
    // write description of contents (name, uuid, buildid)
    write_work_list(&f);
    // Determine unique (module, abspath, mtime) dependencies for the files defining modules in the worklist
    // (see Base._require_dependencies). These get stored in `udeps` and written to the ji-file header.
    // Also write Preferences.
    int64_t srctextpos = write_dependency_list(&f, &udeps);  // srctextpos: position of srctext entry in header index (update later)
    // write description of requirements for loading (modules that must be pre-loaded if initialization is to succeed)
    // this can return errors during deserialize,
    // best to keep it early (before any actual initialization)
    write_mod_list(&f, mod_array);

    arraylist_new(&reinit_list, 0);
    htable_new(&edges_map, 0);
    htable_new(&backref_table, 5000);
    htable_new(&external_mis, newly_inferred ? jl_array_len(newly_inferred) : 0);
    ptrhash_put(&backref_table, jl_main_module, (char*)HT_NOTFOUND + 1);
    backref_table_numel = 1;
    jl_idtable_type = jl_base_module ? jl_get_global(jl_base_module, jl_symbol("IdDict")) : NULL;
    jl_idtable_typename = jl_base_module ? ((jl_datatype_t*)jl_unwrap_unionall((jl_value_t*)jl_idtable_type))->name : NULL;
    jl_bigint_type = jl_base_module ? jl_get_global(jl_base_module, jl_symbol("BigInt")) : NULL;
    if (jl_bigint_type) {
        gmp_limb_size = jl_unbox_long(jl_get_global((jl_module_t*)jl_get_global(jl_base_module, jl_symbol("GMP")),
                                                    jl_symbol("BITS_PER_LIMB"))) / 8;
    }

    int en = jl_gc_enable(0); // edges map is not gc-safe
    jl_array_t *extext_methods = jl_alloc_vec_any(0);  // [method1, simplesig1, ...], worklist-owned "extending external" methods added to functions owned by modules outside the worklist
    jl_array_t *ext_targets = jl_alloc_vec_any(0);     // [callee1, matches1, ...] non-worklist callees of worklist-owned methods
    jl_array_t *edges = jl_alloc_vec_any(0);           // [caller1, ext_targets_indexes1, ...] for worklist-owned methods calling external methods

    int n_ext_mis = queue_external_mis(newly_inferred);

    size_t i;
    size_t len = jl_array_len(mod_array);
    for (i = 0; i < len; i++) {
        jl_module_t *m = (jl_module_t*)jl_array_ptr_ref(mod_array, i);
        assert(jl_is_module(m));
        if (m->parent == m) // some toplevel modules (really just Base) aren't actually
            jl_collect_extext_methods_from_mod(extext_methods, m);
    }
    jl_collect_methtable_from_mod(extext_methods, jl_type_type_mt);
    jl_collect_missing_backedges_to_mod(jl_type_type_mt);
    jl_collect_methtable_from_mod(extext_methods, jl_nonfunction_mt);
    jl_collect_missing_backedges_to_mod(jl_nonfunction_mt);

    // jl_collect_extext_methods_from_mod and jl_collect_missing_backedges_to_mod accumulate data in edges_map.
    // Process this to extract `edges` and `ext_targets`.
    jl_collect_backedges(edges, ext_targets);

    jl_serializer_state s = {
        &f,
        jl_current_task->ptls,
        mod_array
    };
    jl_serialize_value(&s, worklist);   // serialize module-owned items (those accessible from the bindings table)
    jl_serialize_value(&s, extext_methods);  // serialize new worklist-owned methods for external functions
    serialize_htable_keys(&s, &external_mis, n_ext_mis);  // serialize external MethodInstances

    // The next two allow us to restore backedges from external "unserialized" (stub-serialized) MethodInstances
    // to the ones we serialize here
    jl_serialize_value(&s, edges);
    jl_serialize_value(&s, ext_targets);
    jl_finalize_serializer(&s);
    serializer_worklist = NULL;

    jl_gc_enable(en);
    htable_reset(&edges_map, 0);
    htable_reset(&backref_table, 0);
    htable_reset(&external_mis, 0);
    arraylist_free(&reinit_list);

    // Write the source-text for the dependent files
    if (udeps) {
        // Go back and update the source-text position to point to the current position
        int64_t posfile = ios_pos(&f);
        ios_seek(&f, srctextpos);
        write_int64(&f, posfile);
        ios_seek_end(&f);
        // Each source-text file is written as
        //   int32: length of abspath
        //   char*: abspath
        //   uint64: length of src text
        //   char*: src text
        // At the end we write int32(0) as a terminal sentinel.
        len = jl_array_len(udeps);
        ios_t srctext;
        for (i = 0; i < len; i++) {
            jl_value_t *deptuple = jl_array_ptr_ref(udeps, i);
            jl_value_t *depmod = jl_fieldref(deptuple, 0);  // module
            // Dependencies declared with `include_dependency` are excluded
            // because these may not be Julia code (and could be huge)
            if (depmod != (jl_value_t*)jl_main_module) {
                jl_value_t *dep = jl_fieldref(deptuple, 1);  // file abspath
                const char *depstr = jl_string_data(dep);
                if (!depstr[0])
                    continue;
                ios_t *srctp = ios_file(&srctext, depstr, 1, 0, 0, 0);
                if (!srctp) {
                    jl_printf(JL_STDERR, "WARNING: could not cache source text for \"%s\".\n",
                              jl_string_data(dep));
                    continue;
                }
                size_t slen = jl_string_len(dep);
                write_int32(&f, slen);
                ios_write(&f, depstr, slen);
                posfile = ios_pos(&f);
                write_uint64(&f, 0);   // placeholder for length of this file in bytes
                uint64_t filelen = (uint64_t) ios_copyall(&f, &srctext);
                ios_close(&srctext);
                ios_seek(&f, posfile);
                write_uint64(&f, filelen);
                ios_seek_end(&f);
            }
        }
    }
    write_int32(&f, 0); // mark the end of the source text
    ios_close(&f);
    JL_GC_POP();
    jl_precompile_toplevel_module = NULL;

    return 0;
}

#ifndef JL_NDEBUG
// skip the performance optimizations of jl_types_equal and just use subtyping directly
// one of these types is invalid - that's why we're doing the recache type operation
static int jl_invalid_types_equal(jl_datatype_t *a, jl_datatype_t *b)
{
    return jl_subtype((jl_value_t*)a, (jl_value_t*)b) && jl_subtype((jl_value_t*)b, (jl_value_t*)a);
}
STATIC_INLINE jl_value_t *verify_type(jl_value_t *v) JL_NOTSAFEPOINT
{
    assert(v && jl_typeof(v) && jl_typeof(jl_typeof(v)) == (jl_value_t*)jl_datatype_type);
    return v;
}
#endif


static jl_datatype_t *recache_datatype(jl_datatype_t *dt) JL_GC_DISABLED;

static jl_value_t *recache_type(jl_value_t *p) JL_GC_DISABLED
{
    if (jl_is_datatype(p)) {
        jl_datatype_t *pdt = (jl_datatype_t*)p;
        if (ptrhash_get(&uniquing_table, p) != HT_NOTFOUND) {
            p = (jl_value_t*)recache_datatype(pdt);
        }
        else {
            jl_svec_t *tt = pdt->parameters;
            // ensure all type parameters are recached
            size_t i, l = jl_svec_len(tt);
            for (i = 0; i < l; i++)
                jl_svecset(tt, i, recache_type(jl_svecref(tt, i)));
            ptrhash_put(&uniquing_table, p, p); // ensures this algorithm isn't too exponential
        }
    }
    else if (jl_is_typevar(p)) {
        jl_tvar_t *ptv = (jl_tvar_t*)p;
        ptv->lb = recache_type(ptv->lb);
        ptv->ub = recache_type(ptv->ub);
    }
    else if (jl_is_uniontype(p)) {
        jl_uniontype_t *pu = (jl_uniontype_t*)p;
        pu->a = recache_type(pu->a);
        pu->b = recache_type(pu->b);
    }
    else if (jl_is_unionall(p)) {
        jl_unionall_t *pa = (jl_unionall_t*)p;
        pa->var = (jl_tvar_t*)recache_type((jl_value_t*)pa->var);
        pa->body = recache_type(pa->body);
    }
    else {
        jl_datatype_t *pt = (jl_datatype_t*)jl_typeof(p);
        jl_datatype_t *cachep = recache_datatype(pt);
        if (cachep->instance)
            p = cachep->instance;
        else if (pt != cachep)
            jl_set_typeof(p, cachep);
    }
    return p;
}

// Extract pre-existing datatypes from cache, and insert new types into cache
// insertions also update uniquing_table
static jl_datatype_t *recache_datatype(jl_datatype_t *dt) JL_GC_DISABLED
{
    jl_datatype_t *t; // the type after unique'ing
    assert(verify_type((jl_value_t*)dt));
    t = (jl_datatype_t*)ptrhash_get(&uniquing_table, dt);
    if (t == HT_NOTFOUND)
        return dt;
    if (t != NULL)
        return t;

    jl_svec_t *tt = dt->parameters;
    // recache all type parameters
    size_t i, l = jl_svec_len(tt);
    for (i = 0; i < l; i++)
        jl_svecset(tt, i, recache_type(jl_svecref(tt, i)));

    // then recache the type itself
    if (jl_svec_len(tt) == 0) { // jl_cache_type doesn't work if length(parameters) == 0
        t = dt;
    }
    else {
        t = jl_lookup_cache_type_(dt);
        if (t == NULL) {
            jl_cache_type_(dt);
            t = dt;
        }
        assert(t->hash == dt->hash);
        assert(jl_invalid_types_equal(t, dt));
    }
    ptrhash_put(&uniquing_table, dt, t);
    return t;
}

// Recache everything from flagref_list except methods and method instances
// Cleans out any handled items so that anything left in flagref_list still needs future processing
static void jl_recache_types(void) JL_GC_DISABLED
{
    size_t i;
    // first rewrite all the unique'd objects
    for (i = 0; i < flagref_list.len; i += 2) {
        jl_value_t **loc = (jl_value_t**)flagref_list.items[i + 0];
        int offs = (int)(intptr_t)flagref_list.items[i + 1];
        jl_value_t *o = loc ? *loc : (jl_value_t*)backref_list.items[offs];
        if (!jl_is_method(o) && !jl_is_method_instance(o)) {
            jl_datatype_t *dt;
            jl_value_t *v;
            if (jl_is_datatype(o)) {
                dt = (jl_datatype_t*)o;
                v = dt->instance;
            }
            else {
                dt = (jl_datatype_t*)jl_typeof(o);
                v = o;
            }
            jl_datatype_t *t = recache_datatype(dt); // get or create cached type (also updates uniquing_table)
            if ((jl_value_t*)dt == o && t != dt) {
                assert(!type_in_worklist(dt));
                if (loc)
                    *loc = (jl_value_t*)t;
                if (offs > 0)
                    backref_list.items[offs] = t;
            }
            if (v == o && t->instance != v) {
                assert(t->instance);
                assert(loc);
                *loc = t->instance;
                if (offs > 0)
                    backref_list.items[offs] = t->instance;
            }
        }
    }
    // invalidate the old datatypes to help catch errors
    for (i = 0; i < uniquing_table.size; i += 2) {
        jl_datatype_t *o = (jl_datatype_t*)uniquing_table.table[i];      // deserialized ref
        jl_datatype_t *t = (jl_datatype_t*)uniquing_table.table[i + 1];  // the real type
        if (o != t) {
            assert(t != NULL && jl_is_datatype(o));
            if (t->instance != o->instance)
                jl_set_typeof(o->instance, (void*)(intptr_t)0x20);
            jl_set_typeof(o, (void*)(intptr_t)0x10);
        }
    }
    // then do a cleanup pass to drop these from future iterations of flagref_list
    i = 0;
    while (i < flagref_list.len) {
        jl_value_t **loc = (jl_value_t**)flagref_list.items[i + 0];
        int offs = (int)(intptr_t)flagref_list.items[i + 1];
        jl_value_t *o = loc ? *loc : (jl_value_t*)backref_list.items[offs];
        if (jl_is_method(o) || jl_is_method_instance(o)) {
            i += 2;
        }
        else {
            // delete this item from the flagref list, so it won't be re-encountered later
            flagref_list.len -= 2;
            if (i >= flagref_list.len)
                break;
            flagref_list.items[i + 0] = flagref_list.items[flagref_list.len + 0];  // move end-of-list here (executes a `reverse()`)
            flagref_list.items[i + 1] = flagref_list.items[flagref_list.len + 1];
        }
    }
}

// look up a method from a previously deserialized dependent module
static jl_method_t *jl_lookup_method(jl_methtable_t *mt, jl_datatype_t *sig, size_t world)
{
    if (world < jl_main_module->primary_world)
        world = jl_main_module->primary_world;
    struct jl_typemap_assoc search = {(jl_value_t*)sig, world, NULL, 0, ~(size_t)0};
    jl_typemap_entry_t *entry = jl_typemap_assoc_by_type(mt->defs, &search, /*offs*/0, /*subtype*/0);
    return (jl_method_t*)entry->func.value;
}

static jl_method_t *jl_recache_method(jl_method_t *m)
{
    assert(!m->is_for_opaque_closure);
    assert(jl_is_method(m));
    jl_datatype_t *sig = (jl_datatype_t*)m->sig;
    jl_methtable_t *mt = jl_method_get_table(m);
    assert((jl_value_t*)mt != jl_nothing);
    jl_set_typeof(m, (void*)(intptr_t)0x30); // invalidate the old value to help catch errors
    return jl_lookup_method(mt, sig, m->module->primary_world);
}

static jl_value_t *jl_recache_other_(jl_value_t *o);

static jl_method_instance_t *jl_recache_method_instance(jl_method_instance_t *mi)
{
    jl_method_t *m = mi->def.method;
    m = (jl_method_t*)jl_recache_other_((jl_value_t*)m);
    assert(jl_is_method(m));
    jl_datatype_t *argtypes = (jl_datatype_t*)mi->specTypes;
    jl_set_typeof(mi, (void*)(intptr_t)0x40); // invalidate the old value to help catch errors
    jl_svec_t *env = jl_emptysvec;
    jl_value_t *ti = jl_type_intersection_env((jl_value_t*)argtypes, (jl_value_t*)m->sig, &env);
    //assert(ti != jl_bottom_type); (void)ti;
    if (ti == jl_bottom_type)
        env = jl_emptysvec; // the intersection may fail now if the type system had made an incorrect subtype env in the past
    jl_method_instance_t *_new = jl_specializations_get_linfo(m, (jl_value_t*)argtypes, env);
    return _new;
}

static jl_value_t *jl_recache_other_(jl_value_t *o)
{
    jl_value_t *newo = (jl_value_t*)ptrhash_get(&uniquing_table, o);
    if (newo != HT_NOTFOUND)
        return newo;
    if (jl_is_method(o)) {
        // lookup the real Method based on the placeholder sig
        newo = (jl_value_t*)jl_recache_method((jl_method_t*)o);
        ptrhash_put(&uniquing_table, newo, newo);
    }
    else if (jl_is_method_instance(o)) {
        // lookup the real MethodInstance based on the placeholder specTypes
        newo = (jl_value_t*)jl_recache_method_instance((jl_method_instance_t*)o);
    }
    else {
        abort();
    }
    ptrhash_put(&uniquing_table, o, newo);
    return newo;
}

static void jl_recache_other(void)
{
    size_t i = 0;
    while (i < flagref_list.len) {
        jl_value_t **loc = (jl_value_t**)flagref_list.items[i + 0];
        int offs = (int)(intptr_t)flagref_list.items[i + 1];
        jl_value_t *o = loc ? *loc : (jl_value_t*)backref_list.items[offs];
        i += 2;
        jl_value_t *newo = jl_recache_other_(o);
        if (loc)
            *loc = newo;
        if (offs > 0)
            backref_list.items[offs] = newo;
    }
    flagref_list.len = 0;
}

// Wait to copy roots until recaching is done
// This is because recaching requires that all pointers to methods and methodinstances
// stay at their source location as recorded by flagref_list. Once recaching is complete,
// they can be safely copied over.
static void jl_copy_roots(void)
{
    size_t i, j, l;
    for (i = 0; i < queued_method_roots.size; i+=2) {
        jl_method_t *m = (jl_method_t*)queued_method_roots.table[i];
        m = (jl_method_t*)ptrhash_get(&uniquing_table, m);
        jl_svec_t *keyroots = (jl_svec_t*)queued_method_roots.table[i+1];
        if (keyroots != HT_NOTFOUND) {
            uint64_t key = (uint64_t)(uintptr_t)jl_svec_ref(keyroots, 0) | ((uint64_t)(uintptr_t)jl_svec_ref(keyroots, 1) << 32);
            jl_array_t *roots = (jl_array_t*)jl_svec_ref(keyroots, 2);
            assert(jl_is_array(roots));
            l = jl_array_len(roots);
            for (j = 0; j < l; j++) {
                jl_value_t *r = jl_array_ptr_ref(roots, j);
                jl_value_t *newr = (jl_value_t*)ptrhash_get(&uniquing_table, r);
                if (newr != HT_NOTFOUND) {
                    jl_array_ptr_set(roots, j, newr);
                }
            }
            jl_append_method_roots(m, key, roots);
        }
    }
}

static int trace_method(jl_typemap_entry_t *entry, void *closure)
{
    jl_call_tracer(jl_newmeth_tracer, (jl_value_t*)entry->func.method);
    return 1;
}

// Restore module(s) from a cache file f
static jl_value_t *_jl_restore_incremental(ios_t *f, jl_array_t *mod_array)
{
    JL_TIMING(LOAD_MODULE);
    jl_task_t *ct = jl_current_task;
    if (ios_eof(f) || !jl_read_verify_header(f)) {
        ios_close(f);
        return jl_get_exceptionf(jl_errorexception_type,
                "Precompile file header verification checks failed.");
    }
    { // skip past the mod list
        size_t len;
        while ((len = read_int32(f)))
            ios_skip(f, len + 3 * sizeof(uint64_t));
    }
    { // skip past the dependency list
        size_t deplen = read_uint64(f);
        ios_skip(f, deplen);
    }

    jl_bigint_type = jl_base_module ? jl_get_global(jl_base_module, jl_symbol("BigInt")) : NULL;
    if (jl_bigint_type) {
        gmp_limb_size = jl_unbox_long(jl_get_global((jl_module_t*)jl_get_global(jl_base_module, jl_symbol("GMP")),
                                                    jl_symbol("BITS_PER_LIMB"))) / 8;
    }

    // verify that the system state is valid
    jl_value_t *verify_fail = read_verify_mod_list(f, mod_array);
    if (verify_fail) {
        ios_close(f);
        return verify_fail;
    }

    // prepare to deserialize
    int en = jl_gc_enable(0);
    jl_gc_enable_finalizers(ct, 0);
    jl_atomic_fetch_add(&jl_world_counter, 1); // reserve a world age for the deserialization

    arraylist_new(&backref_list, 4000);
    arraylist_push(&backref_list, jl_main_module);
    arraylist_new(&flagref_list, 0);
    htable_new(&queued_method_roots, 0);
    htable_new(&new_code_instance_validate, 0);
    arraylist_new(&ccallable_list, 0);
    htable_new(&uniquing_table, 0);

    jl_serializer_state s = {
        f,
        ct->ptls,
        mod_array
    };
    jl_array_t *restored = (jl_array_t*)jl_deserialize_value(&s, (jl_value_t**)&restored);
    serializer_worklist = restored;
    assert(jl_isa((jl_value_t*)restored, jl_array_any_type));

    // See explanation in jl_save_incremental for variables of the same names
    jl_value_t *extext_methods = jl_deserialize_value(&s, &extext_methods);
    int i, n_ext_mis = read_int32(s.s);
    jl_array_t *mi_list = jl_alloc_vec_any(n_ext_mis);   // reload MIs stored by serialize_htable_keys
    jl_value_t **midata = (jl_value_t**)jl_array_data(mi_list);
    for (i = 0; i < n_ext_mis; i++)
        midata[i] = jl_deserialize_value(&s, &(midata[i]));
    jl_value_t *edges = jl_deserialize_value(&s, &edges);
    jl_value_t *ext_targets = jl_deserialize_value(&s, &ext_targets);

    arraylist_t *tracee_list = NULL;
    if (jl_newmeth_tracer)  // debugging
        tracee_list = arraylist_new((arraylist_t*)malloc_s(sizeof(arraylist_t)), 0);

    // at this point, the AST is fully reconstructed, but still completely disconnected
    // now all of the interconnects will be created
    jl_recache_types(); // make all of the types identities correct
    jl_insert_methods((jl_array_t*)extext_methods); // hook up extension methods for external generic functions (needs to be after recache types)
    jl_recache_other(); // make all of the other objects identities correct (needs to be after insert methods)
    jl_copy_roots();    // copying new roots of external methods (must wait until recaching is complete)
    // At this point, the novel specializations in mi_list reference the real method, but they haven't been cached in its specializations
    jl_insert_method_instances(mi_list);   // insert novel specializations
    htable_free(&uniquing_table);
    jl_array_t *init_order = jl_finalize_deserializer(&s, tracee_list); // done with f and s (needs to be after recache)
    if (init_order == NULL)
        init_order = (jl_array_t*)jl_an_empty_vec_any;
    assert(jl_isa((jl_value_t*)init_order, jl_array_any_type));

    JL_GC_PUSH4(&init_order, &restored, &edges, &ext_targets);
    jl_gc_enable(en); // subtyping can allocate a lot, not valid before recache-other

    jl_insert_backedges((jl_array_t*)edges, (jl_array_t*)ext_targets); // restore external backedges (needs to be last)

    // check new CodeInstances and validate any that lack external backedges
    validate_new_code_instances();

    serializer_worklist = NULL;
    htable_free(&new_code_instance_validate);
    arraylist_free(&flagref_list);
    arraylist_free(&backref_list);
    htable_free(&queued_method_roots);
    ios_close(f);

    jl_gc_enable_finalizers(ct, 1); // make sure we don't run any Julia code concurrently before this point
    if (tracee_list) {
        jl_methtable_t *mt;
        while ((mt = (jl_methtable_t*)arraylist_pop(tracee_list)) != NULL) {
            JL_GC_PROMISE_ROOTED(mt);
            jl_typemap_visitor(mt->defs, trace_method, NULL);
        }
        arraylist_free(tracee_list);
        free(tracee_list);
    }
    for (int i = 0; i < ccallable_list.len; i++) {
        jl_svec_t *item = (jl_svec_t*)ccallable_list.items[i];
        JL_GC_PROMISE_ROOTED(item);
        int success = jl_compile_extern_c(NULL, NULL, NULL, jl_svecref(item, 0), jl_svecref(item, 1));
        if (!success)
            jl_safe_printf("@ccallable was already defined for this method name\n");
    }
    arraylist_free(&ccallable_list);
    jl_value_t *ret = (jl_value_t*)jl_svec(2, restored, init_order);
    JL_GC_POP();

    return (jl_value_t*)ret;
}

JL_DLLEXPORT jl_value_t *jl_restore_incremental_from_buf(const char *buf, size_t sz, jl_array_t *mod_array)
{
    ios_t f;
    ios_static_buffer(&f, (char*)buf, sz);
    return _jl_restore_incremental(&f, mod_array);
}

JL_DLLEXPORT jl_value_t *jl_restore_incremental(const char *fname, jl_array_t *mod_array)
{
    ios_t f;
    if (ios_file(&f, fname, 1, 0, 0, 0) == NULL) {
        return jl_get_exceptionf(jl_errorexception_type,
            "Cache file \"%s\" not found.\n", fname);
    }
    return _jl_restore_incremental(&f, mod_array);
}

// --- init ---

void jl_init_serializer(void)
{
    jl_task_t *ct = jl_current_task;
    htable_new(&ser_tag, 0);
    htable_new(&common_symbol_tag, 0);
    htable_new(&backref_table, 0);

    void *vals[] = { jl_emptysvec, jl_emptytuple, jl_false, jl_true, jl_nothing, jl_any_type,
                     jl_call_sym, jl_invoke_sym, jl_invoke_modify_sym, jl_goto_ifnot_sym, jl_return_sym, jl_symbol("tuple"),
                     jl_an_empty_string, jl_an_empty_vec_any,

                     // empirical list of very common symbols
                     #include "common_symbols1.inc"

                     jl_box_int32(0), jl_box_int32(1), jl_box_int32(2),
                     jl_box_int32(3), jl_box_int32(4), jl_box_int32(5),
                     jl_box_int32(6), jl_box_int32(7), jl_box_int32(8),
                     jl_box_int32(9), jl_box_int32(10), jl_box_int32(11),
                     jl_box_int32(12), jl_box_int32(13), jl_box_int32(14),
                     jl_box_int32(15), jl_box_int32(16), jl_box_int32(17),
                     jl_box_int32(18), jl_box_int32(19), jl_box_int32(20),

                     jl_box_int64(0), jl_box_int64(1), jl_box_int64(2),
                     jl_box_int64(3), jl_box_int64(4), jl_box_int64(5),
                     jl_box_int64(6), jl_box_int64(7), jl_box_int64(8),
                     jl_box_int64(9), jl_box_int64(10), jl_box_int64(11),
                     jl_box_int64(12), jl_box_int64(13), jl_box_int64(14),
                     jl_box_int64(15), jl_box_int64(16), jl_box_int64(17),
                     jl_box_int64(18), jl_box_int64(19), jl_box_int64(20),

                     jl_bool_type, jl_linenumbernode_type, jl_pinode_type,
                     jl_upsilonnode_type, jl_type_type, jl_bottom_type, jl_ref_type,
                     jl_pointer_type, jl_abstractarray_type, jl_nothing_type,
                     jl_vararg_type,
                     jl_densearray_type, jl_function_type, jl_typename_type,
                     jl_builtin_type, jl_task_type, jl_uniontype_type,
                     jl_array_any_type, jl_intrinsic_type,
                     jl_abstractslot_type, jl_methtable_type, jl_typemap_level_type,
                     jl_voidpointer_type, jl_newvarnode_type, jl_abstractstring_type,
                     jl_array_symbol_type, jl_anytuple_type, jl_tparam0(jl_anytuple_type),
                     jl_emptytuple_type, jl_array_uint8_type, jl_code_info_type,
                     jl_typeofbottom_type, jl_typeofbottom_type->super,
                     jl_namedtuple_type, jl_array_int32_type,
                     jl_typedslot_type, jl_uint32_type, jl_uint64_type,
                     jl_type_type_mt, jl_nonfunction_mt,
                     jl_opaque_closure_type,

                     ct->ptls->root_task,

                     NULL };

    // more common symbols, less common than those above. will get 2-byte encodings.
    void *common_symbols[] = {
        #include "common_symbols2.inc"
        NULL
    };

    deser_tag[TAG_SYMBOL] = (jl_value_t*)jl_symbol_type;
    deser_tag[TAG_SSAVALUE] = (jl_value_t*)jl_ssavalue_type;
    deser_tag[TAG_DATATYPE] = (jl_value_t*)jl_datatype_type;
    deser_tag[TAG_SLOTNUMBER] = (jl_value_t*)jl_slotnumber_type;
    deser_tag[TAG_SVEC] = (jl_value_t*)jl_simplevector_type;
    deser_tag[TAG_ARRAY] = (jl_value_t*)jl_array_type;
    deser_tag[TAG_EXPR] = (jl_value_t*)jl_expr_type;
    deser_tag[TAG_PHINODE] = (jl_value_t*)jl_phinode_type;
    deser_tag[TAG_PHICNODE] = (jl_value_t*)jl_phicnode_type;
    deser_tag[TAG_STRING] = (jl_value_t*)jl_string_type;
    deser_tag[TAG_MODULE] = (jl_value_t*)jl_module_type;
    deser_tag[TAG_TVAR] = (jl_value_t*)jl_tvar_type;
    deser_tag[TAG_METHOD_INSTANCE] = (jl_value_t*)jl_method_instance_type;
    deser_tag[TAG_METHOD] = (jl_value_t*)jl_method_type;
    deser_tag[TAG_CODE_INSTANCE] = (jl_value_t*)jl_code_instance_type;
    deser_tag[TAG_GLOBALREF] = (jl_value_t*)jl_globalref_type;
    deser_tag[TAG_INT32] = (jl_value_t*)jl_int32_type;
    deser_tag[TAG_INT64] = (jl_value_t*)jl_int64_type;
    deser_tag[TAG_UINT8] = (jl_value_t*)jl_uint8_type;
    deser_tag[TAG_LINEINFO] = (jl_value_t*)jl_lineinfonode_type;
    deser_tag[TAG_UNIONALL] = (jl_value_t*)jl_unionall_type;
    deser_tag[TAG_GOTONODE] = (jl_value_t*)jl_gotonode_type;
    deser_tag[TAG_QUOTENODE] = (jl_value_t*)jl_quotenode_type;
    deser_tag[TAG_GOTOIFNOT] = (jl_value_t*)jl_gotoifnot_type;
    deser_tag[TAG_RETURNNODE] = (jl_value_t*)jl_returnnode_type;
    deser_tag[TAG_ARGUMENT] = (jl_value_t*)jl_argument_type;

    intptr_t i = 0;
    while (vals[i] != NULL) {
        deser_tag[LAST_TAG+1+i] = (jl_value_t*)vals[i];
        i += 1;
    }
    assert(LAST_TAG+1+i < 256);

    for (i = 2; i < 256; i++) {
        if (deser_tag[i])
            ptrhash_put(&ser_tag, deser_tag[i], (void*)i);
    }

    i = 2;
    while (common_symbols[i-2] != NULL) {
        ptrhash_put(&common_symbol_tag, common_symbols[i-2], (void*)i);
        deser_symbols[i] = (jl_value_t*)common_symbols[i-2];
        i += 1;
    }
    assert(i <= 256);
}

#ifdef __cplusplus
}
#endif
