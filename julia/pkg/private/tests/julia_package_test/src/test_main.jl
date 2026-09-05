module TestPkg
using TestDepPkg
export hello
hello() = TestDepPkg.greet() * " via TestPkg"
end
