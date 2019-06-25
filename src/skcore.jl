using StaticArrays
using SlaterKoster: get_l, get_bidx, bond_to_idx

export @skh_str, SKH


# this assumes that the coordinates are normalised
# TODO: α=φ, β=θ
"""
INPUTS: (x,y,z): This represents a position vector which is given using Cartesian coordinates.
RETURNS: The corresponding polar coordinates - radial, azimuthal, polar.
"""
function carttospher(x,y,z)
   β = acos(z)
   if x != 0
      α = atan(y, x)
   else
      α = sign(y) * π/2
   end
   return α, β
end



struct SKH{SIGN}
   orbitals::Vector{SKOrbital}    # this should become a `species => orbitals` list
   bonds::Vector{SKBond}       # this should become a `(spec1, spec2) => bonds list`
   b2o::Vector{Tuple{Int,Int}}
   locorbidx::Vector{Vector{Int}}
   sig::Type{SIGN}
end

Base.String(H::SKH) = ("sk:" * prod((o.str*":") for o in H.orbitals))[1:end-1]

Base.show(io::IO, H::SKH) = write(io, String(H))

import Base.==
==(H1::SKH, H2::SKH) = all( getproperty(H1, p) == getproperty(H2, p)
                            for p in fieldnames(SKH) )

nbonds(H::SKH) = length(H.bonds)
norbitals(H::SKH) = length(H.orbitals)

"""
`allbonds(orbitals)` : compute all the `SKBond`s between any two
`SKOrbital`s in the list `orbitals` and return as `Vector`.
"""
function allbonds(orbitals::Vector{<: SKOrbital})
   @assert issorted(orbitals)
   norb = length(orbitals)
   bonds = SKBond[]
   idx = 0
   for i1 = 1:norb, i2 = i1:norb
      o1, o2 = orbitals[i1], orbitals[i2]
      for sym in bondtypes(o1, o2)
         idx += 1
         push!(bonds, SKBond(o1, o2, sym, idx))
      end
   end
   return sort(bonds)
end


function SKH(orbitals::AbstractVector{<: SKOrbital},
             bonds::AbstractVector{<: SKBond},
             sig = StandardSigns)
   # check the orbitals have the correct ordering
   @assert issorted(orbitals)
   # construct local orbital -> index mapping
   locorbidx = Vector{Int}[]
   idx = 0
   for orb in orbitals
      len = 2 * get_l(orb) + 1
      push!(locorbidx, Vector{Int}(idx .+ (1:len)))
      idx += len
   end
   # construct local bonds -> orbitals connectivity
   b2o = Tuple{Int, Int}[]
   for b in bonds
      i1 = findfirst(o -> o == b.o1, orbitals)
      i2 = findfirst(o -> o == b.o2, orbitals)
      # insist on an ordering convention
      @assert i1 <= i2
      push!(b2o, (i1, i2))
   end
   return SKH(orbitals, bonds, b2o, locorbidx, sig)
end

_create_idx(orbitals::AbstractVector{<: SKOrbital}) =
   [ SKOrbital(o, idx) for (idx, o) in enumerate(orbitals) ]

function SKH(orbitals::AbstractVector{<: SKOrbital}, sig=StandardSigns)
   orbs_indx = _create_idx(orbitals)
   return SKH(orbs_indx, allbonds(orbs_indx), sig)
end

# experimental constructor for a TB model
function SKH(str::AbstractString, sig = StandardSigns)
   if '0' <= str[1] <= '9'
      @assert iseven(length(str))
      orbitals = [ SKOrbital(str[n:n+1]) for n in 1:2:length(str) ]
   else
      orbitals = [ SKOrbital(str[n:n])   for n = 1:length(str) ]
   end
   return SKH(orbitals, sig)
end

macro skh_str(s) SKH(s) end


max_locidx(H::SKH) = maximum(maximum(I) for I in H.locorbidx)

alloc_block(H::SKH) = zeros(max_locidx(H::SKH), max_locidx(H::SKH))

"""
`sk2cart:` assemble a Slater-Koster matrix block.

**Warning:** this is type-unstable and should not be used to assemble large
Hamiltonians.
"""
function sk2cart(H::SKH, U, V)
   φ, θ = carttospher(U[1], U[2], U[3])
   E = alloc_block(H)
   for (b, Vb, (io1, io2)) in zip(H.bonds, V, H.b2o)
      E12 = CodeGeneration.sk_gen(b, φ, θ)
      I1 = H.locorbidx[io1]
      I2 = H.locorbidx[io2]
      E[I1, I2] .+= (sksign(b) * Vb) * E12
      if io1 != io2
         E[I2, I1] .+= sksignt(b) * Vb * E12'
      end
   end
   return E
end


"""
todo doc
"""
function cart2sk(H::SKH, U, E::AbstractArray)
   φ, θ = carttospher(U[1], U[2], U[3])
   V = zeros(length(H.bonds))
   for (I, (b, (io1, io2))) in enumerate(zip(H.bonds, H.b2o))
      M12 = CodeGeneration.sk_gen(b, φ, θ)
      I1 = H.locorbidx[io1]
      I2 = H.locorbidx[io2]
      bidx = get_bidx(b)
      if bidx > 0
         V[I] += 0.5 * sum(sksign(b) * E[I1, I2] .* M12)
      else
         V[I] += sum(sksign(b) * E[I1, I2] .* M12)
      end
   end
   return V
end
