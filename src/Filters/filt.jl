# Implementations of filt, filtfilt, fftfilt, and firfilt

#
# filt and filt!
#

## TFFilter
_zerosi{T,S}(f::TFFilter{T}, x::AbstractArray{S}) =
    zeros(promote_type(T, S), max(length(f.a), length(f.b))-1)

Base.filt!{T,S}(out, f::TFFilter{T}, x::AbstractArray{S}, si=_zerosi(f, x)) =
    filt!(out, coefb(f), coefa(f), x, si)
Base.filt(f::TFFilter, x, si=_zerosi(f, x)) = filt(coefb(f), coefa(f), x, si)

## SOSFilter
_zerosi{T,G,S}(f::SOSFilter{T,G}, x::AbstractArray{S}) =
    zeros(promote_type(T, G, S), 2, length(f.biquads))

function Base.filt!{S,N}(out::AbstractArray, f::SOSFilter, x::AbstractArray,
                         si::AbstractArray{S,N}=_zerosi(f, x))
    biquads = f.biquads
    ncols = Base.trailingsize(x, 2)

    size(x) != size(out) && error("out size must match x")
    (size(si, 1) != 2 || size(si, 2) != length(biquads) || (N > 2 && Base.trailingsize(si, 3) != ncols)) &&
        error("si must be 2 x nbiquads or 2 x nbiquads x nsignals")

    initial_si = si
    for col = 1:ncols
        si = initial_si[:, :, N > 2 ? col : 1]
        @inbounds for i = 1:size(x, 1)
            yi = x[i, col]
            for fi = 1:length(biquads)
                biquad = biquads[fi]
                xi = yi
                yi = si[1, fi] + biquad.b0*xi
                si[1, fi] = si[2, fi] + biquad.b1*xi - biquad.a1*yi
                si[2, fi] = biquad.b2*xi - biquad.a2*yi
            end
            out[i, col] = yi*f.g
        end
    end
    out
end

Base.filt{T,G,S<:Number}(f::SOSFilter{T,G}, x::AbstractArray{S}, si=_zerosi(f, x)) =
    filt!(Array(promote_type(T, G, S), size(x)), f, x, si)

## BiquadFilter
_zerosi{T,S}(f::BiquadFilter{T}, x::AbstractArray{S}) =
    zeros(promote_type(T, S), 2)

function Base.filt!{S,N}(out::AbstractArray, f::BiquadFilter, x::AbstractArray,
                         si::AbstractArray{S,N}=_zerosi(f, x))
    ncols = Base.trailingsize(x, 2)

    size(x) != size(out) && error("out size must match x")
    (size(si, 1) != 2 || (N > 1 && Base.trailingsize(si, 2) != ncols)) &&
        error("si must have two rows and 1 or nsignals columns")

    initial_si = si
    for col = 1:ncols
        si1 = initial_si[1, N > 1 ? col : 1]
        si2 = initial_si[2, N > 1 ? col : 1]
        @inbounds for i = 1:size(x, 1)
            xi = x[i, col]
            yi = si1 + f.b0*xi
            si1 = si2 + f.b1*xi - f.a1*yi
            si2 = f.b2*xi - f.a2*yi
            out[i, col] = yi
        end
    end
    out
end

Base.filt{T,S<:Number}(f::BiquadFilter{T}, x::AbstractArray{S}, si=_zerosi(f, x)) =
    filt!(Array(promote_type(T, S), size(x)), f, x, si)

## For arbitrary filters, convert to SOSFilter
Base.filt(f::Filter, x) = filt(convert(SOSFilter, f), x)
Base.filt!(out, f::Filter, x) = filt!(out, convert(SOSFilter, f), x)

#
# filtfilt
#

# Extrapolate the beginning of a signal for use by filtfilt. This
# computes:
#
# [(2 * x[1]) .- x[pad_length+1:-1:2],
#  x,
#  (2 * x[end]) .- x[end-1:-1:end-pad_length]]
#
# in place in output. The istart and n parameters determine the portion
# of the input signal x to extrapolate.
function extrapolate_signal!(out, ostart, sig, istart, n, pad_length)
    length(out) >= n+2*pad_length || error("output is incorrectly sized")
    x = 2*sig[istart]
    for i = 1:pad_length
        out[ostart+i-1] = x - sig[istart+pad_length+1-i]
    end
    copy!(out, ostart+pad_length, sig, istart, n)
    x = 2*sig[istart+n-1]
    for i = 1:pad_length
        out[ostart+n+pad_length+i-1] = x - sig[istart+n-1-i]
    end
    out
end

# Zero phase digital filtering by processing data in forward and reverse direction
function iir_filtfilt(b::AbstractVector, a::AbstractVector, x::AbstractArray)
    zi = filt_stepstate(b, a)
    zitmp = copy(zi)
    pad_length = 3 * (max(length(a), length(b)) - 1)
    t = Base.promote_eltype(b, a, x)
    extrapolated = Array(t, size(x, 1)+pad_length*2)
    out = similar(x, t)

    istart = 1
    for i = 1:Base.trailingsize(x, 2)
        extrapolate_signal!(extrapolated, 1, x, istart, size(x, 1), pad_length)
        reverse!(filt!(extrapolated, b, a, extrapolated, scale!(zitmp, zi, extrapolated[1])))
        filt!(extrapolated, b, a, extrapolated, scale!(zitmp, zi, extrapolated[1]))
        for j = 1:size(x, 1)
            @inbounds out[j, i] = extrapolated[end-pad_length+1-j]
        end
        istart += size(x, 1)
    end

    out
end

# Zero phase digital filtering with an FIR filter in a single pass
function fir_filtfilt(b::AbstractVector, x::AbstractArray)
    nb = length(b)
    # Only need as much padding as the order of the filter
    t = Base.promote_eltype(b, x)
    extrapolated = similar(x, t, size(x, 1)+2nb-2, Base.trailingsize(x, 2))

    # Convolve b with its reverse
    newb = firfilt(b, reverse(b))
    resize!(newb, 2nb-1)
    for i = 1:nb-1
        newb[nb+i] = newb[nb-i]
    end

    # Extrapolate each column
    for i = 1:size(extrapolated, 2)
        extrapolate_signal!(extrapolated, (i-1)*size(extrapolated, 1)+1, x, (i-1)*size(x, 1)+1, size(x, 1), nb-1)
    end

    # Filter
    out = firfilt(newb, extrapolated)

    # Drop garbage at start
    reshape(out[2nb-1:end, :], size(x))
end

# Choose whether to use fir_filtfilt or iir_filtfilt depending on
# length of a
function filtfilt(b::AbstractVector, a::AbstractVector, x::AbstractArray)
    if length(a) == 1
        if a[1] != 1
            b /= a[1]
        end
        fir_filtfilt(b, x)
    else
        iir_filtfilt(b, a, x)
    end
end

# Extract si for a biquad, multiplied by a scaling factor
function biquad_si!(zitmp, zi, i, scal)
    zitmp[1] = zi[1, i]*scal
    zitmp[2] = zi[2, i]*scal
    zitmp
end

# Zero phase digital filtering for second order sections
function filtfilt{T,G,S}(f::SOSFilter{T,G}, x::AbstractArray{S})
    zi = filt_stepstate(f)
    zi2 = zeros(2)
    zitmp = zeros(2)
    pad_length = 3*size(zi, 1)
    t = Base.promote_type(T, G, S)
    extrapolated = Array(t, size(x, 1)+pad_length*2)
    out = similar(x, t)

    istart = 1
    for i = 1:size(x, 2)
        # First biquad
        extrapolate_signal!(extrapolated, 1, x, istart, size(x, 1), pad_length)
        f2 = f.biquads[1]*f.g
        reverse!(filt!(extrapolated, f2, extrapolated, biquad_si!(zitmp, zi, 1, extrapolated[1])))
        reverse!(filt!(extrapolated, f2, extrapolated, biquad_si!(zitmp, zi, 1, extrapolated[1])))

        # Subsequent biquads
        for j = 2:length(f.biquads)
            f2 = f.biquads[j]
            extrapolate_signal!(extrapolated, 1, extrapolated, pad_length+1, size(x, 1), pad_length)
            reverse!(filt!(extrapolated, f2, extrapolated, biquad_si!(zitmp, zi, j, extrapolated[1])))
            reverse!(filt!(extrapolated, f2, extrapolated, biquad_si!(zitmp, zi, j, extrapolated[1])))
        end

        # Copy to output
        copy!(out, istart, extrapolated, pad_length+1, size(x, 1))
        istart += size(x, 1)
    end

    out
end

# Support for other filter types
filtfilt(f::Filter, x) = filtfilt(convert(SOSFilter, f), x)
filtfilt(f::TFFilter, x) = filtfilt(coefb(f), coefa(f), x)

## Initial filter state

# Compute an initial state for filt with coefficients (b,a) such that its
# response to a step function is steady state.
function filt_stepstate{T<:Number}(b::Union(AbstractVector{T}, T), a::Union(AbstractVector{T}, T))
    scale_factor = a[1]
    if scale_factor != 1.0
        a = a ./ scale_factor
        b = b ./ scale_factor
    end

    bs = length(b)
    as = length(a)
    sz = max(bs, as)
    sz > 0 || error("a and b must have at least one element each")
    sz == 1 && return T[]

    # Pad the coefficients with zeros if needed
    bs<sz && (b = copy!(zeros(eltype(b), sz), b))
    as<sz && (a = copy!(zeros(eltype(a), sz), a))

    # construct the companion matrix A and vector B:
    A = [-a[2:end] [eye(T, sz-2); zeros(T, 1, sz-2)]]
    B = b[2:end] - a[2:end] * b[1]
    # Solve si = A*si + B
    # (I - A)*si = B
    scale_factor \ (I - A) \ B
 end

function filt_stepstate{T}(f::SOSFilter{T})
    biquads = f.biquads
    si = Array(T, 2, length(biquads))
    for i = 1:length(biquads)
        biquad = biquads[i]
        A = [one(T)+biquad.a1 -one(T)
                   +biquad.a2  one(T)]
        B = [biquad.b1 - biquad.a1*biquad.b0,
             biquad.b2 - biquad.a2*biquad.b0]
        si[:, i] = A \ B
    end
    si[1, 1] *= f.g
    si[2, 1] *= f.g
    si
end

#
# fftfilt and firfilt
#

const FFT_LENGTHS = 2.^(1:28)
# FFT times computed on a Core i7-3930K @4.4GHz
# The real time doesn't matter, just the relative difference
const FFT_TIMES = [6.36383e-7, 6.3779e-7 , 6.52212e-7, 6.65282e-7, 7.12794e-7, 7.63172e-7,
                   7.91914e-7, 1.02289e-6, 1.37939e-6, 2.10868e-6, 4.04436e-6, 9.12889e-6,
                   2.32142e-5, 4.95576e-5, 0.000124927, 0.000247771, 0.000608867, 0.00153119,
                   0.00359037, 0.0110568, 0.0310893, 0.065813, 0.143516, 0.465745, 0.978072,
                   2.04371, 4.06017, 8.77769]

# Determine optimal length of the FFT for fftfilt
function optimalfftfiltlength(nb, nx)
    nfft = 0
    if nb > FFT_LENGTHS[end] || nb >= nx
        nfft = nextfastfft(nx+nb-1)
    else
        fastestestimate = Inf
        firsti = max(1, searchsortedfirst(FFT_LENGTHS, nb))
        lasti = max(1, searchsortedfirst(FFT_LENGTHS, nx+nb-1))
        L = 0
        for i = firsti:lasti
            curL = FFT_LENGTHS[i] - (nb - 1)
            estimate = iceil(nx/curL)*FFT_TIMES[i]
            if estimate < fastestestimate
                nfft = FFT_LENGTHS[i]
                fastestestimate = estimate
                L = curL
            end
        end

        if L > nx
            # If L > nx, better to find next fast power
            nfft = nextfastfft(nx+nb-1)
        end
    end
    nfft
end

# Filter x using FIR filter b by overlap-save method
function fftfilt{T<:Real}(b::AbstractVector{T}, x::AbstractArray{T},
                          nfft=optimalfftfiltlength(length(b), length(x)))
    nb = length(b)
    nx = size(x, 1)
    normfactor = 1/nfft

    L = min(nx, nfft - (nb - 1))
    tmp1 = Array(T, nfft)
    tmp2 = Array(Complex{T}, nfft << 1 + 1)
    out = Array(T, size(x))

    p1 = FFTW.Plan(tmp1, tmp2, 1, FFTW.ESTIMATE, FFTW.NO_TIMELIMIT)
    p2 = FFTW.Plan(tmp2, tmp1, 1, FFTW.ESTIMATE, FFTW.NO_TIMELIMIT)

    # FFT of filter
    filterft = similar(tmp2)
    copy!(tmp1, b)
    tmp1[nb+1:end] = zero(T)
    FFTW.execute(p1.plan, tmp1, filterft)

    # FFT of chunks
    for colstart = 0:nx:length(x)-1
        off = 1
        while off <= nx
            npadbefore = max(0, nb - off)
            xstart = off - nb + npadbefore + 1
            n = min(nfft - npadbefore, nx - xstart + 1)

            tmp1[1:npadbefore] = zero(T)
            tmp1[npadbefore+n+1:end] = zero(T)

            copy!(tmp1, npadbefore+1, x, colstart+xstart, n)
            FFTW.execute(T, p1.plan)
            broadcast!(*, tmp2, tmp2, filterft)
            FFTW.execute(T, p2.plan)

            # Copy to output
            for j = 0:min(L - 1, nx - off)
                @inbounds out[colstart+off+j] = tmp1[nb+j]*normfactor
            end

            off += L
        end
    end

    out
end

# Filter x using FIR filter b, heuristically choosing to perform
# convolution in the time domain using filt or in the frequency domain
# using fftfilt
function firfilt{T<:Number}(b::AbstractVector{T}, x::AbstractArray{T})
    nb = length(b)
    nx = size(x, 1)

    filtops = length(x) * min(nx, nb)
    if filtops <= 100000
        # 65536 is apprximate cutoff where FFT-based algorithm may be
        # more effective (due to overhead for allocation, plan
        # creation, etc.)
        filt(b, [one(T)], x)
    else
        # Estimate number of multiplication operations for fftfilt()
        # and filt()
        nfft = optimalfftfiltlength(nb, nx)
        L = min(nx, nfft - (nb - 1))
        nchunk = iceil(nx/L)*div(length(x), nx)
        fftops = (2*nchunk + 1) * nfft * log2(nfft)/2 + nchunk * nfft + 100000

        filtops > fftops ? fftfilt(b, x, nfft) : filt(b, [one(T)], x)
    end
end