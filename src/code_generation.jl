
__precompile__(false)
module CodeGeneration

using PyCall, Calculus

using SlaterKoster: max_symbol, bondintegral_index, orbital_index


# load the python part of the code generation
const _pysys = pyimport("sys")
push!(_pysys."path", @__DIR__())
const _codegen = pyimport("codegen")

sympy = pyimport("sympy")
sp_spin = pyimport("sympy.physics.quantum.spin")

const spsin = sympy.sin
const spcos = sympy.cos
const Rotation = sp_spin.Rotation


"""
## INPUTS

'l_1': Angular quantum number of atom 1.
'l_2': Angular quantum number of atom 2.
     l        : 0  1  2  3  4
     orbitals : s  p  d  f  g  h  j  k ...
'm_1': Magnetic quantum number of atom 1.
'm_2': Magnetic quantum number of atom 2.
     m : sub-orbitals for the ls

'M': A float which represents the type of symmetry bond we are considering,
        M | 0 1 2 3 4
    symbol| σ π δ φ γ

## RETURNS

This function returns the relevant coefficient that should be are used in writing the
Slater-Koster transformations.
"""
function Gsym_old(l_1, l_2, m_1, m_2, M::Integer)
   str = _codegen.Gsym(l_1, l_2, m_1, m_2, M)
   # replace some symbols to turn python into julia code
   str = replace(str, "**" => "^")
   # α : Azithmuthal coordinate (normally φ)
   str = replace(str, "alpha" => "φ")   # the python code uses alpha here
   # β : Polar angle (normally θ)
   str = replace(str, "beta" => "θ")   # the python code uses alpha here
   return str
end



"""
INPUTS: l_1: Angular quantum number of atom 1.
        l_2: Angular quantum number of atom 2.
        m_1: Magnetic quantum number of atom 1.
        m_2: Magnetic quantum number of atom 2.
        M: A float which represents the type of symmetry bond we are considering, e.g. M = 0
           for sigma, M = 1 for pi, M = 2 for delta, etc.
        alpha: Azithmuthal coordinate.
        beta: Polar coordinate.
RETURNS: This function returns the relevant coefficient that should be are used in writing the
         Slater-Koster transformations.
"""
function Gsym(l1, l2, m1, m2, sym)

   φ, θ = sympy.symbols("phi, theta")

   τ(m) = (m >= 0) ? 1 : 0

   A(m, φ) = ( (m == 0) ? sympy.sqrt(2)/2 :
               (-1)^m * (τ(m) * spcos(abs(m)*φ) + τ(-m) * spsin(abs(m)*φ)) )

   B(m, φ) = ( (m == 0) ? 0 :
               (-1)^m * (τ(-m) * spcos(abs(m)*φ) - τ(m) * spsin(abs(m)*φ) ) )

   rot(l, m, sym, θ) = Rotation.d(l, m, sym, θ).doit()

   S(l, m, sym, φ, θ) = A(m, φ) * ( (-1)^sym * rot(l, abs(m),  sym, θ)
                                             + rot(l, abs(m), -sym, θ) )

   T(l, m, sym, φ, θ) = B(m, φ) * ( (-1)^sym * rot(l, abs(m),  sym, θ)
                                             - rot(l, abs(m), -sym, θ) )

   if sym == 0
      expr = (2 * A(m1, φ) * rot(l1, abs(m1), 0, θ)
                * A(m2, φ) * rot(l2, abs(m2), 0, θ) )
   else
      expr = (   S(l1, m1, sym, φ, θ) * S(l2, m2, sym, φ, θ)
               + T(l1, m1, sym, φ, θ) * T(l2, m2, sym, φ, θ) )
   end

   expr = expr.simplify()

   # x, y, z = sympy.symbols("x y z")
   # expr = expr.simplify()
   # expr = expr.subs(spsin(φ) * spsin(θ), y)
   # expr = expr.subs(spcos(φ) * spsin(θ), x)
   # expr = expr.subs(spcos(θ), z)
   # # expr = expr.subs(spsin(φ)^2, 1.0 - spcos(φ)^2)
   # expr = expr.simplify()

   # convert the sympy expression into a string
   return py2jlcode(expr.__str__())
end

function py2jlcode(str)
   # replace some symbols to turn python into julia code
   str = replace(str, "**" => "^")
   # φ : Azithmuthal coordinate
   str = replace(str, "phi" => "φ")   # the python code uses alpha here
   # θ : Polar angle
   str = replace(str, "theta" => "θ")   # the python code uses alpha here
end


struct StandardSigns end
signmod(::Type{StandardSigns}, args...) = 1

struct FHISigns end
signmod(::Type{FHISigns}, l1, l2, m1, m2) =
   _codegen.signmatrix(l1, l2)[l1+m1+1, l2+m2+1]

# Standard SK Sign convention???
# TODO: Confirm this is ok as a sign convention!!!
sksign(l1, l2) = (isodd(l1+l2) && (l1 > l2)) ? -1 : 1

@generated function sk_gen!(g, ::Val{L}, V, φ, θ,
                            sgnconv::Type{SGN} = StandardSigns
                            ) where {L, SGN}
   code = Expr[]
   for l1 = 0:L, l2 = 0:L, m1 = -l1:l1, m2 = -l2:l2
      # matrix indices
      I1 = orbital_index(l1, m1)
      I2 = orbital_index(l2, m2)
      # sign modification (to do the FHI modification)
      sig = sksign(l1, l2) * signmod(SGN)
      # start assembling the expression for this matrix entry
      ex = "0.0"
      for sym = 0:max_symbol(l1, l2)
         # expression for the new entry
         ex1 = Gsym(l1, l2, m1, m2, sym)
         # extression for the bond integral V
         V_idx = bondintegral_index(l1, l2, sym)
         ex = "$ex + ($ex1) * V[$V_idx]"
      end
      ex_assign = " g[$I1, $I2] = $sig * ($ex) "
      push!(code, Calculus.simplify(Meta.parse(ex_assign)))
   end
   quote
      $(Expr(:block, code...))
      return g
   end
end


end
