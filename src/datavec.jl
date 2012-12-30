##############################################################################
##
## Definitions for 1D Data* types which can contain NA's
##
## Inspirations:
##  * R's NA's
##  * Panda's discussion of NA's:
##    http://pandas.pydata.org/pandas-docs/stable/missing_data.html
##  * NumPy's analysis of the issue:
##    https://github.com/numpy/numpy/blob/master/doc/neps/missing-data.rst
##
## NAtype is a composite type representing missingness:
## * An object of NAtype can be generated by writing NA
##
## AbstractDataVec's are an abstract type that can contain NA's:
##  * The core derived composite type is DataVec, which is a parameterized type
##    that wraps an vector of a type and a Boolean (bit) array for the mask.
##  * A secondary derived composite type is a PooledDataVec, which is a
##    parameterized type that wraps a vector of UInts and a vector of one type,
##    indexed by the main vector. NA's are 0's in the UInt vector.
##
##############################################################################

##############################################################################
##
## NA's via the NAtype
##
##############################################################################

type NAtype; end
const NA = NAtype()
show(io, x::NAtype) = print(io, "NA")

type NAException <: Exception
    msg::String
end

length(x::NAtype) = 1
size(x::NAtype) = ()

##############################################################################
##
## DataVec type definition
##
##############################################################################

abstract AbstractDataVec{T} <: AbstractVector{T}

type DataVec{T} <: AbstractDataVec{T}
    data::Vector{T}
    na::BitVector

    # Sanity check that new data values and missingness metadata match
    function DataVec(new_data::Vector{T}, is_missing::BitVector)
        if length(new_data) != length(is_missing)
            error("Data and missingness vectors not the same length!")
        end
        new(new_data, is_missing)
    end
end

##############################################################################
##
## DataVec constructors
##
##############################################################################

# Need to redefine inner constructor as outer constuctor for parametric types
DataVec{T}(d::Vector{T}, n::BitVector) = DataVec{T}(d, n)

# Need to redefine inner constructor as outer constuctor for parametric types
function DataVec{T}(d::AbstractVector{T}, n::BitVector)
    DataVec{T}(convert(Vector{T}, d), n)
end

# Convert Vector{Bool}'s to BitVector's to save space
DataVec{T}(d::Vector{T}, m::Vector{Bool}) = DataVec{T}(d, bitpack(m))

# Convert an existing vector to a DataVec w/ no NA's
DataVec{T}(x::Vector{T}) = DataVec(x, falses(length(x)))

# Convert a BitVector to a Vector{Bool} before making a DataVec
DataVec(d::BitVector, m::BitVector) = DataVec(convert(Vector{Bool}, d), m)

# Convert a BitVector to a DataVec w/ no NA's
DataVec(d::BitVector) = DataVec(convert(Vector{Bool}, d), falses(length(d)))

# Convert a Ranges into a DataVec
DataVec{T}(r::Ranges{T}) = DataVec([r], falses(length(r)))

# A no-op constructor
DataVec(d::DataVec) = d

# Construct an all-NA DataVec of a specific type
DataVec(t::Type, n::Int) = DataVec(Array(t, n), trues(n))

# Construct an all-NA DataVec of the default column type
DataVec(n::Int) = DataVec(Array(DEFAULT_COLUMN_TYPE, n), trues(n))

# Construct an all-NA DataVec of the default column type with length 0
DataVec() = DataVec(Array(DEFAULT_COLUMN_TYPE, 0), trues(0))

# Initialized constructors with 0's, 1's
for (f, basef) in ((:dvzeros, :zeros), (:dvones, :ones))
    @eval begin
        ($f)(n::Int) = DataVec(($basef)(n), falses(n))
        ($f)(t::Type, n::Int) = DataVec(($basef)(t, n), falses(n))
    end
end

# Initialized constructors with false's or true's
for (f, basef) in ((:dvfalses, :falses), (:dvtrues, :trues))
    @eval begin
        ($f)(n::Int) = DataVec(($basef)(n), falses(n))
    end
end

# Super-hacked out constructor: DataVec[1, 2, NA]
# Need to do type inference
function _dv_most_generic_type(vals)
    # iterate over vals tuple to find the most generic non-NA type
    toptype = None
    for i = 1:length(vals)
        if !isna(vals[i])
            toptype = promote_type(toptype, typeof(vals[i]))
        end
    end
    if !method_exists(baseval, (toptype, ))
        error("No baseval exists for type: $(toptype)")
    end
    return toptype
end
function ref(::Type{DataVec}, vals...)
    # Get the most generic non-NA type
    toptype = _dv_most_generic_type(vals)

    # Allocate an empty DataVec
    lenvals = length(vals)
    res = DataVec(Array(toptype, lenvals), BitVector(lenvals))

    # Copy from vals into data and mask
    for i = 1:lenvals
        if isna(vals[i])
            res.data[i] = baseval(toptype)
            res.na[i] = true
        else
            res.data[i] = vals[i]
            res.na[i] = false
        end
    end

    return res
end

##############################################################################
##
## PooledDataVec type definition
##
## A DataVec with efficient storage when values are repeated
## TODO: Make sure we don't overflow from refs being Uint16
## TODO: Allow ordering of factor levels
## TODO: Add metadata for dummy conversion
##
##############################################################################

type PooledDataVec{T} <: AbstractDataVec{T}
    refs::Vector{POOLED_DATA_VEC_REF_TYPE}
    pool::Vector{T}

    function PooledDataVec{T}(rs::Vector{POOLED_DATA_VEC_REF_TYPE}, p::Vector{T})
        # refs mustn't overflow pool
        if max(rs) > length(p)
            error("Reference vector points beyond the end of the pool")
        end
        new(rs, p)
    end
end

##############################################################################
##
## PooledDataVec constructors
##
##############################################################################

# A no-op constructor
PooledDataVec(d::PooledDataVec) = d

# Echo inner constructor as an outer constructor
function PooledDataVec{T}(refs::Vector{POOLED_DATA_VEC_REF_TYPE}, pool::Vector{T})
    PooledDataVec{T}(refs, pool)
end

# How do you construct a PooledDataVec from a Vector?
# From the same sigs as a DataVec!
# Algorithm:
# * Start with:
#   * A null pool
#   * A pre-allocated refs
#   * A hash from T to Int
# * Iterate over d
#   * If value of d in pool already, set the refs accordingly
#   * If value is new, add it to the pool, then set refs
function PooledDataVec{T}(d::Vector{T}, m::AbstractArray{Bool,1})
    newrefs = Array(POOLED_DATA_VEC_REF_TYPE, length(d))
    newpool = Array(T, 0)
    poolref = Dict{T, POOLED_DATA_VEC_REF_TYPE}(0) # Why isn't this a set?
    maxref = 0

    # Loop through once to fill the poolref dict
    for i = 1:length(d)
        if !m[i]
            poolref[d[i]] = 0
        end
    end

    # Fill positions in poolref
    newpool = sort(keys(poolref))
    i = 1
    for p in newpool
        poolref[p] = i
        i += 1
    end

    # Fill in newrefs
    for i = 1:length(d)
        if m[i]
            newrefs[i] = 0
        else
            newrefs[i] = poolref[d[i]]
        end
    end

    return PooledDataVec(newrefs, newpool)
end

# Allow a pool to be provided by the user
function PooledDataVec{T}(d::Vector{T}, pool::Vector{T}, m::AbstractVector{Bool})
    if length(pool) > typemax(POOLED_DATA_VEC_REF_TYPE)
        error("Cannot construct a PooledDataVec with such a large pool")
    end

    newrefs = Array(POOLED_DATA_VEC_REF_TYPE, length(d))
    poolref = Dict{T, POOLED_DATA_VEC_REF_TYPE}(0)
    maxref = 0

    # loop through once to fill the poolref dict
    for i = 1:length(pool)
        poolref[pool[i]] = 0
    end

    # fill positions in poolref
    newpool = sort(keys(poolref))
    i = 1
    for p in newpool
        poolref[p] = i
        i += 1
    end

    # fill in newrefs
    for i = 1:length(d)
        if m[i]
            newrefs[i] = 0
        else
            if has(poolref, d[i])
              newrefs[i] = poolref[d[i]]
            else
              error("Vector contains elements not in provided pool")
            end
        end
    end

    return PooledDataVec(newrefs, newpool)
end

# Convert a BitVector to a Vector{Bool} w/ specified missingness
function PooledDataVec(d::BitVector, m::AbstractVector{Bool})
    PooledDataVec(convert(Vector{Bool}, d), m)
end

# Convert a DataVec to a PooledDataVec
PooledDataVec{T}(dv::DataVec{T}) = PooledDataVec(dv.data, dv.na)

# Convert a Vector{T} to a PooledDataVec
PooledDataVec{T}(x::Vector{T}) = PooledDataVec(x, falses(length(x)))

# Convert a BitVector to a Vector{Bool} w/o specified missingness
function PooledDataVec(x::BitVector)
    PooledDataVec(convert(Vector{Bool}, x), falses(length(x)))
end

# Explicitly convert Ranges into a PooledDataVec
PooledDataVec{T}(r::Ranges{T}) = PooledDataVec([r], falses(length(r)))

# Construct an all-NA PooledDataVec of a specific type
PooledDataVec(t::Type, n::Int) = PooledDataVec(Array(t, n), trues(n))

# Construct an all-NA PooledDataVec of the default column type
PooledDataVec(n::Int) = PooledDataVec(Array(DEFAULT_COLUMN_TYPE, n), trues(n))

# Construct an all-NA PooledDataVec of the default column type with length 0
PooledDataVec() = PooledDataVec(Array(DEFAULT_COLUMN_TYPE, 0), trues(0))

# Specify just a vector and a pool
function PooledDataVec{T}(d::Vector{T}, pool::Vector{T})
    PooledDataVec(d, pool, falses(length(d)))
end

# Initialized constructors with 0's, 1's
for (f, basef) in ((:pdvzeros, :zeros), (:pdvones, :ones))
    @eval begin
        ($f)(n::Int) = PooledDataVec(($basef)(n), falses(n))
        ($f)(t::Type, n::Int) = PooledDataVec(($basef)(t, n), falses(n))
    end
end

# Initialized constructors with false's or true's
for (f, basef) in ((:pdvfalses, :falses), (:pdvtrues, :trues))
    @eval begin
        ($f)(n::Int) = PooledDataVec(($basef)(n), falses(n))
    end
end

# Super hacked-out constructor: PooledDataVec[1, 2, 2, NA]
function ref(::Type{PooledDataVec}, vals...)
    # For now, just create a DataVec and then convert it
    # TODO: Rewrite for speed
    PooledDataVec(DataVec[vals...])
end

##############################################################################
##
## Basic size properties of all Data* objects
##
##############################################################################

size(v::DataVec) = size(v.data)
size(v::PooledDataVec) = size(v.refs)
length(v::DataVec) = length(v.data)
length(v::PooledDataVec) = length(v.refs)
ndims(v::AbstractDataVec) = 1
numel(v::AbstractDataVec) = length(v)
eltype{T}(v::AbstractDataVec{T}) = T

##############################################################################
##
## Copying Data* objects
##
##############################################################################

copy{T}(dv::DataVec{T}) = DataVec{T}(copy(dv.data), copy(dv.na))
copy{T}(dv::PooledDataVec{T}) = PooledDataVec{T}(copy(dv.refs), copy(dv.pool))
# TODO: Implement copy_to()

##############################################################################
##
## Predicates, including the new isna()
##
##############################################################################

function isnan{T}(dv::DataVec{T})
    DataVec(isnan(dv.data), copy(dv.na))
end

function isnan{T}(pdv::PooledDataVec{T})
    PooledDataVec(copy(pdv.refs), isnan(dv.pool))
end

function isfinite{T}(dv::DataVec{T})
    DataVec(isfinite(dv.data), copy(dv.na))
end

function isfinite{T}(dv::PooledDataVec{T})
    PooledDataVec(copy(pdv.refs), isfinite(dv.pool))
end

isna(x::NAtype) = true
isna(v::DataVec) = copy(v.na)
isna(v::PooledDataVec) = v.refs .== 0
isna(x::AbstractArray) = falses(size(x))
isna(x::Any) = false

function any_na{T}(dv::AbstractDataVec{T})
    for i in 1:length(dv)
        if isna(dv[i])
            return true
        end
    end
    return false
end

##############################################################################
##
## PooledDataVec utilities
##
## TODO: Add methods with these names for DataVec's
##       Decide whether levels() or unique() is primitive. Make the other
##       an alias.
##
##############################################################################

# Convert a PooledDataVec{T} to a DataVec{T}
function values{T}(x::PooledDataVec{T})
    n = length(x)
    res = DataVec(T, n)
    for i in 1:n
        r = x.refs[i]
        if r == 0
            res[i] = NA
        else
            res[i] = x.pool[r]
        end
    end
    return res
end
DataVec(pdv::PooledDataVec) = values(pdv)
values{T}(dv::DataVec{T}) = copy(dv)

function unique{T}(x::PooledDataVec{T})
    if any(x.refs .== 0)
        n = length(x.pool)
        d = Array(T, n + 1)
        for i in 1:n
            d[i] = x.pool[i]
        end
        m = falses(n + 1)
        m[n + 1] = true
        return DataVec(d, m)
    else
        return DataVec(copy(x.pool), falses(length(x.pool)))
    end
end
levels{T}(pdv::PooledDataVec{T}) = unique(pdv)

function unique{T}(adv::AbstractDataVec{T})
  values = Dict{Union(T, NAtype), Bool}()
  for i in 1:length(adv)
    values[adv[i]] = true
  end
  unique_values = keys(values)
  res = DataVec(T, length(unique_values))
  for i in 1:length(unique_values)
    res[i] = unique_values[i]
  end
  return res
end
levels{T}(adv::AbstractDataVec{T}) = unique(adv)

get_indices{T}(x::PooledDataVec{T}) = x.refs

function index_to_level{T}(x::PooledDataVec{T})
    d = Dict{POOLED_DATA_VEC_REF_TYPE, T}()
    for i in POOLED_DATA_VEC_REF_CONVERTER(1:length(x.pool))
        d[i] = x.pool[i]
    end
    return d
end

function level_to_index{T}(x::PooledDataVec{T})
    d = Dict{T, POOLED_DATA_VEC_REF_TYPE}()
    for i in POOLED_DATA_VEC_REF_CONVERTER(1:length(x.pool))
        d[x.pool[i]] = i
    end
    d
end

##############################################################################
##
## find()
##
##############################################################################

function find(dv::DataVec{Bool})
    n = length(dv)
    res = Array(Int, n)
    bound = 0
    for i in 1:length(dv)
        if !dv.na[i] && dv.data[i]
            bound += 1
            res[bound] = i
        end
    end
    return res[1:bound]
end

find(pdv::PooledDataVec{Bool}) = find(values(pdv))

##############################################################################
##
## Generic Strategies for dealing with NA's
##
## Editing Functions:
##
## * failNA: Operations should die on the presence of NA's.
## * removeNA: What was once called FILTER.
## * replaceNA: What was once called REPLACE.
##
## Iterator Functions:
##
## * each_failNA: Operations should die on the presence of NA's.
## * each_removeNA: What was once called FILTER.
## * each_replaceNA: What was once called REPLACE.
##
## v = failNA(dv)
##
## for v in each_failNA(dv)
##     do_something_with_value(v)
## end
##
##############################################################################

function failNA{T}(dv::DataVec{T})
    n = length(dv)
    for i in 1:n
        if dv.na[i]
            error("Failing after encountering an NA")
        end
    end
    return copy(dv.data)
end

function removeNA{T}(dv::DataVec{T})
    return copy(dv.data[!dv.na])
end

function replaceNA{S, T}(dv::DataVec{S}, replacement_val::T)
    n = length(dv)
    res = copy(dv.data)
    for i in 1:n
        if dv.na[i]
            res[i] = replacement_val
        end
    end
    return res
end

# TODO: Re-implement these methods more efficently
function failNA{T}(dv::AbstractDataVec{T})
    n = length(dv)
    for i in 1:n
        if isna(dv[i])
            error("Failing after encountering an NA")
        end
    end
    return convert(Vector{T}, [x::T for x in dv])
end

function removeNA{T}(dv::AbstractDataVec{T})
    return convert(Vector{T}, [x::T for x in dv[!isna(dv)]])
end

function replaceNA{S, T}(dv::AbstractDataVec{S}, replacement_val::T)
    n = length(dv)
    res = Array(S, n)
    for i in 1:n
        if isna(dv[i])
            res[i] = replacement_val
        else
            res[i] = dv[i]
        end
    end
    return res
end

# TODO: Remove this?
vector{T}(dv::AbstractDataVec{T}) = failNA(dv)

type EachFailNA{T}
    dv::AbstractDataVec{T}
end
each_failNA{T}(dv::AbstractDataVec{T}) = EachFailNA(dv)
start(itr::EachFailNA) = 1
function done(itr::EachFailNA, ind::Int)
    return ind > length(itr.dv)
end
function next(itr::EachFailNA, ind::Int)
    if isna(itr.dv[ind])
        error("NA's encountered. Failing...")
    else
        (itr.dv[ind], ind + 1)
    end
end

type EachRemoveNA{T}
    dv::AbstractDataVec{T}
end
each_removeNA{T}(dv::AbstractDataVec{T}) = EachRemoveNA(dv)
start(itr::EachRemoveNA) = 1
function done(itr::EachRemoveNA, ind::Int)
    return ind > length(itr.dv)
end
function next(itr::EachRemoveNA, ind::Int)
    while ind <= length(itr.dv) && isna(itr.dv[ind])
        ind += 1
    end
    (itr.dv[ind], ind + 1)
end

type EachReplaceNA{T}
    dv::AbstractDataVec{T}
    replacement_val::T
end
each_replaceNA{T}(dv::AbstractDataVec{T}, v::T) = EachReplaceNA(dv, v)
start(itr::EachReplaceNA) = 1
function done(itr::EachReplaceNA, ind::Int)
    return ind > length(itr.dv)
end
function next(itr::EachReplaceNA, ind::Int)
    if isna(itr.dv[ind])
        (itr.replacement_val, ind + 1)
    else
        (itr.dv[ind], ind + 1)
    end
end

##############################################################################
##
## similar()
##
##############################################################################

# TODO: Make these work using DataArray
function similar{T}(dv::DataVec{T}, dim::Int)
    DataVec(Array(T, dim), trues(dim))
end

function similar{T}(dv::DataVec{T}, dims::Dims)
    DataVec(Array(T, dims), trues(dims))
end

function similar{T}(dv::PooledDataVec{T}, dim::Int)
    PooledDataVec(fill(uint16(0), dim), dv.pool)
end

function similar{T}(dv::PooledDataVec{T}, dims::Dims)
    PooledDataVec(fill(uint16(0), dims), dv.pool)
end

##############################################################################
##
## ref()
##
##############################################################################

# dv[SingleItemIndex]
function ref(x::DataVec, ind::Integer)
    if x.na[ind]
        return NA
    else
        return x.data[ind]
    end
end
function ref(x::PooledDataVec, ind::Integer)
    if x.refs[ind] == 0
        return NA
    else
        return x.pool[x.refs[ind]]
    end
end

# dv[MultiItemIndex]
function ref(x::DataVec, inds::AbstractDataVec{Bool})
    inds = find(replaceNA(inds, false))
    return DataVec(x.data[inds], x.na[inds])
end
function ref(x::PooledDataVec, inds::AbstractDataVec{Bool})
    inds = find(replaceNA(inds, false))
    return PooledDataVec(x.refs[inds], copy(x.pool))
end
function ref(x::DataVec, inds::AbstractDataVec)
    inds = removeNA(inds)
    return DataVec(x.data[inds], x.na[inds])
end
function ref(x::PooledDataVec, inds::AbstractDataVec)
    inds = removeNA(inds)
    return PooledDataVec(x.refs[inds], copy(x.pool))
end
# TODO: Find a way to get these next two functions to use AbstractVector
function ref(x::DataVec, inds::Union(Vector, BitVector, Ranges))
    return DataVec(x.data[inds], x.na[inds])
end
function ref(x::PooledDataVec, inds::Union(Vector, BitVector, Ranges))
    return PooledDataVec(x.refs[inds], copy(x.pool))
end

# v[dv]
function ref(x::Vector, inds::AbstractDataVec{Bool})
    inds = find(replaceNA(inds, false))
    return x[inds]
end
function ref{S, T}(x::Vector{S}, inds::AbstractDataVec{T})
    inds = removeNA(inds)
    return x[inds]
end

##############################################################################
##
## assign() definitions
##
##############################################################################

# x[SingleIndex] = NA
function assign(x::DataVec, val::NAtype, ind::Integer)
    x.na[ind] = true
    return NA
end
# TODO: Delete values from pool that no longer exist?
function assign(x::PooledDataVec, val::NAtype, ind::Integer)
    x.refs[ind] = 0
    return NA
end

# x[SingleIndex] = Single Item
function assign(x::DataVec, val::Any, ind::Integer)
    x.data[ind] = val
    x.na[ind] = false
    return val
end
# TODO: Delete values from pool that no longer exist?
function assign(x::PooledDataVec, val::Any, ind::Integer)
    val = convert(eltype(x), val)
    pool_idx = findfirst(x.pool, val)
    if pool_idx > 0
        x.refs[ind] = pool_idx
    else
        push(x.pool, val)
        x.refs[ind] = length(x.pool)
    end
    return val
end

# x[MultiIndex] = NA
# TODO: Find a way to delete the next four methods
function assign(x::DataVec{NAtype}, val::NAtype, inds::AbstractVector{Bool})
    error("Don't use DataVec{NAtype}'s")
end
function assign(x::PooledDataVec{NAtype}, val::NAtype, inds::AbstractVector{Bool})
    error("Don't use PooledDataVec{NAtype}'s")
end
function assign(x::DataVec{NAtype}, val::NAtype, inds::AbstractVector)
    error("Don't use DataVec{NAtype}'s")
end
function assign(x::PooledDataVec{NAtype}, val::NAtype, inds::AbstractVector)
    error("Don't use PooledDataVec{NAtype}'s")
end

# x[MultiIndex] = NA
function assign(x::DataVec, val::NAtype, inds::AbstractVector)
    x.na[inds] = true
    return NA
end
# TODO: Delete values from pool that no longer exist?
function assign(x::PooledDataVec, val::NAtype, inds::AbstractVector)
    x.refs[inds] = 0
    return NA
end

# x[MultiIndex] = Multiple Values
# TODO: Delete values from pool that no longer exist?
function assign(x::AbstractDataVec,
                vals::AbstractVector,
                inds::AbstractVector{Bool})
    assign(x, vals, find(inds))
end
function assign(x::AbstractDataVec,
                vals::AbstractVector,
                inds::AbstractVector)
    for (val, ind) in zip(vals, inds)
        x[ind] = val
    end
    return vals
end

# x[MultiIndex] = Single Item
# Single item can be a Number, String or the eltype of the AbstractDataVec
# Should be val::Union(Number, String, T), but that doesn't work
# TODO: Delete values from pool that no longer exist?
function assign{T}(x::AbstractDataVec{T},
                   val::Number,
                   inds::AbstractVector{Bool})
    assign(x, val, find(inds))
end
function assign{T}(x::AbstractDataVec{T},
                   val::Number,
                   inds::AbstractVector)
    val = convert(eltype(x), val)
    for ind in inds
        x[ind] = val
    end
    return val
end
function assign{T}(x::AbstractDataVec{T},
                   val::String,
                   inds::AbstractVector{Bool})
    assign(x, val, find(inds))
end
function assign{T}(x::AbstractDataVec{T},
                   val::String,
                   inds::AbstractVector)
    val = convert(eltype(x), val)
    for ind in inds
        x[ind] = val
    end
    return val
end
function assign{T}(x::AbstractDataVec{T},
                   val::T,
                   inds::AbstractVector{Bool})
    assign(x, val, find(inds))
end
function assign{T}(x::AbstractDataVec{T},
                   val::T,
                   inds::AbstractVector)
    val = convert(eltype(x), val)
    for ind in inds
        x[ind] = val
    end
    return val
end

##############################################################################
##
## Generic iteration over AbstractDataVec's
##
##############################################################################

start(x::AbstractDataVec) = 1
function next(x::AbstractDataVec, state::Int)
    return (x[state], state+1)
end
function done(x::AbstractDataVec, state::Int)
    return state > length(x)
end

##############################################################################
##
## Promotion rules
##
##############################################################################

promote_rule{T, T}(::Type{AbstractDataVec{T}}, ::Type{T}) = promote_rule(T, T)
promote_rule{S, T}(::Type{AbstractDataVec{S}}, ::Type{T}) = promote_rule(S, T)
promote_rule{T}(::Type{AbstractDataVec{T}}, ::Type{T}) = T

##############################################################################
##
## Conversion rules
##
##############################################################################

# TODO: Get rid of these
function convert{N}(::Type{BitArray{N}}, x::DataVec{BitArray{N}})
    error("Invalid DataVec")
end
function convert{N}(::Type{BitArray{N}}, x::AbstractDataVec{BitArray{N}})
    error("Invalid AbstractDataVec")
end

function convert{T}(::Type{T}, x::DataVec{T})
    if any_na(x)
        err = "Cannot convert DataVec with NA's to base type"
        throw(NAException(err))
    else
        return x.data
    end
end

function convert{T}(::Type{T}, x::AbstractDataVec{T})
    try
        return [i::T for i in x]
    catch ee
        if isa(ee, TypeError)
            err = "Cannot convert AbstractDataVec with NA's to base type"
            throw(NAException(err))
        else
            throw(ee)
        end
    end
end

##############################################################################
##
## Conversion convenience functions
##
##############################################################################

for f in (:int, :float, :bool)
    @eval begin
        function ($f){T}(dv::DataVec{T})
            if !any_na(dv)
                ($f)(dv.data)
            else
                error("Conversion impossible with NA's present")
            end
        end
    end
end
for (f, basef) in ((:dvint, :int), (:dvfloat, :float64), (:dvbool, :bool))
    @eval begin
        function ($f){T}(dv::DataVec{T})
            DataVec(($basef)(dv.data), copy(dv.na))
        end
    end
end

##############################################################################
##
## String representations and printing
##
## TODO: Inherit these from AbstractArray after implementing DataArray
##
##############################################################################

function string(x::AbstractDataVec)
    tmp = join(x, ", ")
    return "[$tmp]"
end

show(io, x::AbstractDataVec) = Base.show_comma_array(io, x, '[', ']')

function show{T}(io, x::PooledDataVec{T})
    print("values: ")
    print(values(x))
    print("\n")
    print("levels: ")
    print(levels(x))
end

function repl_show{T}(io::IO, dv::DataVec{T})
    n = length(dv)
    print(io, "$n-element $T DataVec\n")
    if n == 0
        return
    end
    max_lines = tty_rows() - 4
    head_lim = fld(max_lines, 2)
    if mod(max_lines, 2) == 0
        tail_lim = (n - fld(max_lines, 2)) + 2
    else
        tail_lim = (n - fld(max_lines, 2)) + 1
    end
    if n > max_lines
        for i in 1:head_lim
            println(io, strcat(' ', dv[i]))
        end
        println(io, " \u22ee")
        for i in tail_lim:(n - 1)
            println(io, strcat(' ', dv[i]))
        end
        print(io, strcat(' ', dv[n]))
    else
        for i in 1:(n - 1)
            println(io, strcat(' ', dv[i]))
        end
        print(io, strcat(' ', dv[n]))
    end
end

function repl_show{T}(io::IO, dv::PooledDataVec{T})
    n = length(dv)
    print(io, "$n-element $T PooledDataVec\n")
    if n == 0
        return
    end
    max_lines = tty_rows() - 5
    head_lim = fld(max_lines, 2)
    if mod(max_lines, 2) == 0
        tail_lim = (n - fld(max_lines, 2)) + 2
    else
        tail_lim = (n - fld(max_lines, 2)) + 1
    end
    if n > max_lines
        for i in 1:head_lim
            println(io, strcat(' ', dv[i]))
        end
        println(io, " \u22ee")
        for i in tail_lim:(n - 1)
            println(io, strcat(' ', dv[i]))
        end
        println(io, strcat(' ', dv[n]))
    else
        for i in 1:(n - 1)
            println(io, strcat(' ', dv[i]))
        end
        println(io, strcat(' ', dv[n]))
    end
    print(io, "levels: ")
    print(io, levels(dv))
end

head{T}(dv::DataVec{T}) = repl_show(dv[1:min(6, length(dv))])

tail{T}(dv::DataVec{T}) = repl_show(dv[max(length(dv) - 6, 1):length(dv)])

##############################################################################
##
## Container operations
##
##############################################################################

# TODO: Fill in definitions for PooledDataVec's
# TODO: Macroize these definitions

function push{T}(dv::DataVec{T}, v::NAtype)
    push(dv.data, baseval(T))
    push(dv.na, true)
    return v
end

function push{S, T}(dv::DataVec{S}, v::T)
    push(dv.data, v)
    push(dv.na, false)
    return v
end

function pop{T}(dv::DataVec{T})
    d, m = pop(dv.data), pop(dv.na)
    if m
        return NA
    else
        return d
    end
end

function enqueue{T}(dv::DataVec{T}, v::NAtype)
    enqueue(dv.data, baseval(T))
    enqueue(dv.na, true)
    return v
end

function enqueue{S, T}(dv::DataVec{S}, v::T)
    enqueue(dv.data, v)
    enqueue(dv.na, false)
    return v
end

function shift{T}(dv::DataVec{T})
    d, m = shift(dv.data), shift(dv.na)
    if m
        return NA
    else
        return d
    end
end

function map{T}(f::Function, dv::DataVec{T})
    n = length(dv)
    res = DataVec(Any, n)
    for i in 1:n
        res[i] = f(dv[i])
    end
    return res
end

##############################################################################
##
## Replacement operations
##
##############################################################################

function replace!(x::PooledDataVec{NAtype}, fromval::NAtype, toval::NAtype)
    NA # no-op to deal with warning
end
function replace!{R}(x::PooledDataVec{R}, fromval::NAtype, toval::NAtype)
    NA # no-op to deal with warning
end
function replace!{S, T}(x::PooledDataVec{S}, fromval::T, toval::NAtype)
    fromidx = findfirst(x.pool, fromval)
    if fromidx == 0
        error("can't replace a value not in the pool in a PooledDataVec!")
    end

    x.refs[x.refs .== fromidx] = 0

    return NA
end
function replace!{S, T}(x::PooledDataVec{S}, fromval::NAtype, toval::T)
    toidx = findfirst(x.pool, toval)
    # if toval is in the pool, just do the assignment
    if toidx != 0
        x.refs[x.refs .== 0] = toidx
    else
        # otherwise, toval is new, add it to the pool
        push(x.pool, toval)
        x.refs[x.refs .== 0] = length(x.pool)
    end

    return toval
end
function replace!{R, S, T}(x::PooledDataVec{R}, fromval::S, toval::T)
    # throw error if fromval isn't in the pool
    fromidx = findfirst(x.pool, fromval)
    if fromidx == 0
        error("can't replace a value not in the pool in a PooledDataVec!")
    end

    # if toval is in the pool too, use that and remove fromval from the pool
    toidx = findfirst(x.pool, toval)
    if toidx != 0
        x.refs[x.refs .== fromidx] = toidx
        #x.pool[fromidx] = None    TODO: what to do here??
    else
        # otherwise, toval is new, swap it in
        x.pool[fromidx] = toval
    end

    return toval
end

##############################################################################
##
## Sorting
##
## TODO: Remove
##
##############################################################################

sort(pd::PooledDataVec) = pd[order(pd)]
order(pd::PooledDataVec) = groupsort_indexer(pd)[1]

##############################################################################
##
## Tabulation
##
##############################################################################

function table{T}(d::AbstractDataVec{T})
    counts = Dict{Union(T, NAtype), Int}(0)
    for i = 1:length(d)
        if has(counts, d[i])
            counts[d[i]] += 1
        else
            counts[d[i]] = 1
        end
    end
    return counts
end

##############################################################################
##
## paste()
##
##############################################################################

const letters = convert(Vector{ASCIIString}, split("abcdefghijklmnopqrstuvwxyz", ""))
const LETTERS = convert(Vector{ASCIIString}, split("ABCDEFGHIJKLMNOPQRSTUVWXYZ", ""))

# Like string(s), but preserves Vector{String} and converts
# Vector{Any} to Vector{String}.
_vstring{T <: String}(s::T) = s
_vstring{T <: String}(s::Vector{T}) = s
_vstring(s::Vector) = map(_vstring, s)
_vstring(s::Any) = string(s)

function paste{T<:String}(s::Vector{T}...)
    sa = {s...}
    N = max(length, sa)
    res = fill("", N)
    for i in 1:length(sa)
        Ni = length(sa[i])
        k = 1
        for j = 1:N
            res[j] = strcat(res[j], sa[i][k])
            if k == Ni   # This recycles array elements.
                k = 1
            else
                k += 1
            end
        end
    end
    res
end
# The following converts all arguments to Vector{<:String} before
# calling paste.
function paste(s...)
    converted = map(vcat * _vstring, {s...})
    paste(converted...)
end

##############################################################################
##
## cut()
##
##############################################################################

function cut{S, T}(x::Vector{S}, breaks::Vector{T})
    if !issorted(breaks)
        sort!(breaks)
    end
    min_x, max_x = min(x), max(x)
    if breaks[1] > min_x
        unshift(breaks, min_x)
    end
    if breaks[end] < max_x
        push(breaks, max_x)
    end
    refs = fill(POOLED_DATA_VEC_REF_CONVERTER(0), length(x))
    for i in 1:length(x)
        if x[i] == min_x
            refs[i] = 1
        else
            refs[i] = search_sorted(breaks, x[i]) - 1
        end
    end
    n = length(breaks)
    from = map(x -> sprint(showcompact, x), breaks[1:(n - 1)])
    to = map(x -> sprint(showcompact, x), breaks[2:n])
    pool = Array(ASCIIString, n - 1)
    if breaks[1] == min_x
        pool[1] = strcat("[", from[1], ",", to[1], "]")
    else
        pool[1] = strcat("(", from[1], ",", to[1], "]")
    end
    for i in 2:(n - 1)
        pool[i] = strcat("(", from[i], ",", to[i], "]")
    end
    PooledDataVec(refs, pool)
end
cut(x::Vector, ngroups::Int) = cut(x, quantile(x, [1 : ngroups - 1] / ngroups))

##############################################################################
##
## PooledDataVecs: EXPLANATION SHOULD GO HERE
##
##############################################################################

function PooledDataVecs{S, T}(v1::AbstractDataVec{S}, v2::AbstractDataVec{T})
    ## Return two PooledDataVecs that share the same pool.

    refs1 = Array(POOLED_DATA_VEC_REF_TYPE, length(v1))
    refs2 = Array(POOLED_DATA_VEC_REF_TYPE, length(v2))
    poolref = Dict{T,POOLED_DATA_VEC_REF_TYPE}(length(v1))
    maxref = 0

    # loop through once to fill the poolref dict
    for i = 1:length(v1)
        ## TODO see if we really need the NA checking here.
        ## if !isna(v1[i])
            poolref[v1[i]] = 0
        ## end
    end
    for i = 1:length(v2)
        ## if !isna(v2[i])
            poolref[v2[i]] = 0
        ## end
    end

    # fill positions in poolref
    pool = sort(keys(poolref))
    i = 1
    for p in pool
        poolref[p] = i
        i += 1
    end

    # fill in newrefs
    for i = 1:length(v1)
        ## if isna(v1[i])
        ##     refs1[i] = 0
        ## else
            refs1[i] = poolref[v1[i]]
        ## end
    end
    for i = 1:length(v2)
        ## if isna(v2[i])
        ##     refs2[i] = 0
        ## else
            refs2[i] = poolref[v2[i]]
        ## end
    end
    (PooledDataVec(refs1, pool),
     PooledDataVec(refs2, pool))
end
