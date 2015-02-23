// Distilled from GenericPricing.
//
// This test does not actually have anything to do with split, but
// rather exposed a bug in array index generation due to a typo in the
// scalar expression module (see commit
// d4a3f6f313deb2d246c15c30bcb095afa1095338).  This test still has
// value since apparently no other part of the test suite triggered
// this code path.

fun [real] take(int n, [real] a) =
  let {first, rest} = split(n, a) in
  first

fun [real] fftmp([[real]] md_c) =
  map( fn real (int j) =>
         let x = take(j,md_c[j])
         in  reduce(op +, 0.0, x),
       iota(size(0, md_c))
     )

fun [real] main([[[real]]] all_md_c) =
  let md_c = all_md_c[0] in
  fftmp(md_c)
