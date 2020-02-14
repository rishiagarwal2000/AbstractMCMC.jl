module AbstractMCMC

using ProgressMeter
import StatsBase
using StatsBase: sample

using Random: GLOBAL_RNG, AbstractRNG, seed!

"""
    AbstractChains

`AbstractChains` is an abstract type for an object that stores
parameter samples generated through a MCMC process.
"""
abstract type AbstractChains end

chainscat(c::AbstractChains...) = cat(c...; dims=3)

"""
    AbstractSampler

The `AbstractSampler` type is intended to be inherited from when
implementing a custom sampler. Any persistent state information should be
saved in a subtype of `AbstractSampler`.

When defining a new sampler, you should also overload the function
`transition_type`, which tells the `sample` function what type of parameter
it should expect to receive.
"""
abstract type AbstractSampler end

"""
    AbstractModel

An `AbstractModel` represents a generic model type that can be used to perform inference.
"""
abstract type AbstractModel end

"""
    AbstractCallback

An `AbstractCallback` types is a supertype to be inherited from if you want to use custom callback 
functionality. This is used to report sampling progress such as parameters calculated, remaining
samples to run, or even plot graphs if you so choose.

In order to implement callback functionality, you need the following:

- A mutable struct that is a subtype of `AbstractCallback`
- An overload of the `init_callback` function
- An overload of the `callback` function
"""
abstract type AbstractCallback end

"""
    NoCallback()

This disables the callback functionality in the event that you wish to 
implement your own callback or reporting.
"""
mutable struct NoCallback <: AbstractCallback end

"""
    DefaultCallback(N::Int)

The default callback struct which uses `ProgressMeter`.
"""
mutable struct DefaultCallback{
    ProgType<:ProgressMeter.AbstractProgress
} <: AbstractCallback
    p :: ProgType
end

DefaultCallback(N::Int) = DefaultCallback(ProgressMeter.Progress(N, 1))

function init_callback(
    rng::AbstractRNG,
    ℓ::ModelType,
    s::SamplerType,
    N::Integer;
    kwargs...
) where {ModelType<:AbstractModel, SamplerType<:AbstractSampler}
    return DefaultCallback(N)
end

"""
    _generate_callback(
        rng::AbstractRNG,
        ℓ::ModelType,
        s::SamplerType,
        N::Integer;
        progress_style=:default,
        kwargs...
    )

`_generate_callback` uses a `progress_style` keyword argument to determine
which progress meter style should be used. This function is strictly internal
and is not meant to be overloaded. If you intend to add a custom `AbstractCallback`,
you should overload `init_callback` instead.

Options for `progress_style` include:

    - `:default` which returns the result of `init_callback`
    - `false` or `:disable` which returns a `NoCallback`
    - `:plain` which returns the default, simple `DefaultCallback`.
"""
function _generate_callback(
    rng::AbstractRNG,
    ℓ::ModelType,
    s::SamplerType,
    N::Integer;
    progress_style=:default,
    kwargs...
) where {ModelType<:AbstractModel, SamplerType<:AbstractSampler}
    if progress_style == :default
        return init_callback(rng, ℓ, s, N; kwargs...)
    elseif progress_style == false || progress_style == :disable
        return NoCallback()
    elseif progress_style == :plain
        return DefaultCallback(N)
    else
        throw(ArgumentError("Keyword argument $progress_style is not recognized."))
    end
end

"""
    sample([rng, ]model, sampler, N; kwargs...)

Return `N` samples from the MCMC `sampler` for the provided `model`.
"""
function StatsBase.sample(
    model::AbstractModel,
    sampler::AbstractSampler,
    N::Integer;
    kwargs...
)
    return sample(GLOBAL_RNG, model, sampler, N; kwargs...)
end

function StatsBase.sample(
    rng::AbstractRNG,
    model::AbstractModel,
    sampler::AbstractSampler,
    N::Integer;
    progress::Bool=true,
    chain_type::Type=Any,
    kwargs...
)
    # Check the number of requested samples.
    N > 0 || error("the number of samples must be ≥ 1")

    # Perform any necessary setup.
    sample_init!(rng, model, sampler, N; kwargs...)

    # Add a progress meter.
    progress && (cb = _generate_callback(rng, model, sampler, N; kwargs...))

    # Obtain the initial transition.
    transition = step!(rng, model, sampler, N; iteration=1, kwargs...)

    # Save the transition.
    transitions = transitions_init(transition, model, sampler, N; kwargs...)
    transitions_save!(transitions, 1, transition, model, sampler, N; kwargs...)

    # Update the progress meter.
    progress && callback(rng, model, sampler, N, 1, transition, cb; kwargs...)

    # Step through the sampler.
    for i in 2:N
        # Obtain the next transition.
        transition = step!(rng, model, sampler, N, transition; iteration=i, kwargs...)

        # Save the transition.
        transitions_save!(transitions, i, transition, model, sampler, N; kwargs...)

        # Update the progress meter.
        progress && callback(rng, model, sampler, N, i, transition, cb; kwargs...)
    end

    # Wrap up the sampler, if necessary.
    sample_end!(rng, model, sampler, N, transitions; kwargs...)

    return bundle_samples(rng, model, sampler, N, transitions, chain_type; kwargs...)
end

"""
    sample_init!(rng, model, sampler, N[; kwargs...])

Perform the initial setup of the MCMC `sampler` for the provided `model`.

This function is not intended to return any value, any set up should mutate the `sampler`
or the `model` in-place. A common use for `sample_init!` might be to instantiate a particle
field for later use, or find an initial step size for a Hamiltonian sampler.
"""
function sample_init!(
    ::AbstractRNG,
    model::AbstractModel,
    sampler::AbstractSampler,
    ::Integer;
    kwargs...
)
    @debug "the default `sample_init!` function is used" typeof(model) typeof(sampler)
    return
end

"""
    sample_end!(rng, model, sampler, N, transitions[; kwargs...])

Perform final modifications after sampling from the MCMC `sampler` for the provided `model`,
resulting in the provided `transitions`.

This function is not intended to return any value, any set up should mutate the `sampler`
or the `model` in-place.

This function is useful in cases where you might want to transform the `transitions`,
save the `sampler` to disk, or perform any clean-up or finalization.
"""
function sample_end!(
    ::AbstractRNG,
    model::AbstractModel,
    sampler::AbstractSampler,
    ::Integer,
    transitions;
    kwargs...
)
    @debug "the default `sample_end!` function is used" typeof(model) typeof(sampler) typeof(transitions)
    return
end

function bundle_samples(
    ::AbstractRNG, 
    ::AbstractModel, 
    ::AbstractSampler, 
    ::Integer, 
    transitions,
    ::Type{Any}; 
    kwargs...
)
    return transitions
end

"""
    step!(rng, model, sampler[, N = 1, transition = nothing; kwargs...])

Return the transition for the next step of the MCMC `sampler` for the provided `model`,
using the provided random number generator `rng`.

Transitions describe the results of a single step of the `sampler`. As an example, a
transition might include a vector of parameters sampled from a prior distribution.

The `step!` function may modify the `model` or the `sampler` in-place. For example, the
`sampler` may have a state variable that contains a vector of particles or some other value
that does not need to be included in the returned transition.

When sampling from the `sampler` using [`sample`](@ref), every `step!` call after the first
has access to the previous `transition`. In the first call, `transition` is set to `nothing`.
"""
function step!(
    ::AbstractRNG,
    model::AbstractModel,
    sampler::AbstractSampler,
    ::Integer = 1,
    transition = nothing;
    kwargs...
)
    error("function `step!` is not implemented for models of type $(typeof(model)), ",
        "samplers of type $(typeof(sampler)), and transitions of type $(typeof(transition))")
end

"""
    transitions_init(transition, model, sampler, N[; kwargs...])

Generate a container for the `N` transitions of the MCMC `sampler` for the provided
`model`, whose first transition is `transition`.
"""
function transitions_init(
    transition,
    ::AbstractModel,
    ::AbstractSampler,
    N::Integer;
    kwargs...
)
    return Vector{typeof(transition)}(undef, N)
end

"""
    transitions_save!(transitions, iteration, transition, model, sampler, N[; kwargs...])

Save the `transition` of the MCMC `sampler` at the current `iteration` in the container of
`transitions`.
"""
function transitions_save!(
    transitions::AbstractVector,
    iteration::Integer,
    transition,
    ::AbstractModel,
    ::AbstractSampler,
    ::Integer;
    kwargs...
)
    transitions[iteration] = transition
    return
end

"""
    callback(
        rng::AbstractRNG,
        ℓ::ModelType,
        s::SamplerType,
        N::Integer,
        iteration::Integer,
        cb::CallbackType;
        kwargs...
    )

`callback` is called after every sample run, and allows you to run some function on a 
subtype of `AbstractCallback`. Typically this is used to increment a progress meter, show a 
plot of parameter draws, or otherwise provide information about the sampling process to the user.

By default, `ProgressMeter` is used to show the number of samples remaning.
"""
function callback(
    rng::AbstractRNG,
    ℓ::ModelType,
    s::SamplerType,
    N::Integer,
    iteration::Integer,
    transition,
    cb::CallbackType;
    kwargs...
) where {
    ModelType<:AbstractModel,
    SamplerType<:AbstractSampler,
    CallbackType<:AbstractCallback,
}
    # Default callback behavior.
    ProgressMeter.next!(cb.p)
end

function callback(
    rng::AbstractRNG,
    ℓ::ModelType,
    s::SamplerType,
    N::Integer,
    iteration::Integer,
    transition,
    cb::NoCallback;
    kwargs...
) where {
    ModelType<:AbstractModel,
    SamplerType<:AbstractSampler,
}
    # Do nothing.
end

"""
    psample([rng::AbstractRNG, ]model::AbstractModel, sampler::AbstractSampler, N::Integer,
            nchains::Integer; kwargs...)

Sample `nchains` chains using the available threads, and combine them into a single chain.

By default, the random number generator, the model and the samplers are deep copied for each
thread to prevent contamination between threads. 
"""
function psample(
    model::AbstractModel,
    sampler::AbstractSampler,
    N::Integer,
    nchains::Integer;
    kwargs...
)
    return psample(GLOBAL_RNG, model, sampler, N, nchains; kwargs...)
end

function psample(
    rng::AbstractRNG,
    model::AbstractModel,
    sampler::AbstractSampler,
    N::Integer,
    nchains::Integer;
    kwargs...
)
    # Copy the random number generator, model, and sample for each thread
    rngs = [deepcopy(rng) for _ in 1:Threads.nthreads()]
    models = [deepcopy(model) for _ in 1:Threads.nthreads()]
    samplers = [deepcopy(sampler) for _ in 1:Threads.nthreads()]

    # Create a seed for each chain using the provided random number generator.
    seeds = rand(rng, UInt, nchains)

    # Set up a chains vector.
    chains = Vector{Any}(undef, nchains)

    Threads.@threads for i in 1:nchains
        # Obtain the ID of the current thread.
        id = Threads.threadid()

        # Seed the thread-specific random number generator with the pre-made seed.
        subrng = rngs[id]
        seed!(subrng, seeds[i])
        
        # Sample a chain and save it to the vector.
        chains[i] = sample(subrng, models[id] , samplers[id], N; progress=false, kwargs...)
    end

    # Concatenate the chains together.
    return reduce(chainscat, chains)
end


##################
# Iterator tools #
##################
struct Stepper{A<:AbstractRNG, ModelType<:AbstractModel, SamplerType<:AbstractSampler, K}
    rng::A
    model::ModelType
    s::SamplerType
    kwargs::K
end

function Base.iterate(stp::Stepper, state=nothing)
    t = step!(stp.rng, stp.model, stp.s, 1, state; stp.kwargs...)
    return t, t
end

Base.IteratorSize(::Type{<:Stepper}) = Base.IsInfinite()
Base.IteratorEltype(::Type{<:Stepper}) = Base.EltypeUnknown()

"""
    steps!([rng::AbstractRNG, ]model::AbstractModel, s::AbstractSampler, kwargs...)

`steps!` returns an iterator that returns samples continuously, after calling `sample_init!`.

Usage:

```julia
for transition in steps!(MyModel(), MySampler())
    println(transition)

    # Do other stuff with transition below.
end
```
"""
function steps!(
    model::AbstractModel,
    s::AbstractSampler,
    kwargs...
)
    return steps!(GLOBAL_RNG, model, s; kwargs...)
end

function steps!(
    rng::AbstractRNG,
    model::AbstractModel,
    s::AbstractSampler,
    kwargs...
)
    sample_init!(rng, model, s, 0)
    return Stepper(rng, model, s, kwargs)
end

end # module AbstractMCMC
