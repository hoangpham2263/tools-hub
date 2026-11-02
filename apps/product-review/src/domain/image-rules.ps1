# One core rule set for how the product must look in the result, the same for every product type (furniture, garments,
# anything else). Per-type blocks (dining seating, worn garment) only add placement; they never restate these.
function Get-ImageCoreRules([int]$ProductIndex) {
    @"
CORE PRODUCT RULES (image $ProductIndex is the product photo; these apply to every product):
1. SOURCE: image $ProductIndex is the only source for how the product looks. The text note only names things; where it differs from image $ProductIndex, follow image $ProductIndex.
2. COLOR: reproduce the color you see on the product in image $ProductIndex, part by part: hue, depth (light or dark) and saturation. Judge it on evenly lit areas, not on glare, deep shadow or a color cast of image $ProductIndex's own room. Do not brighten, warm up, restain or improve it. Image 1's room must not tint it: cool grey floors, marble, white walls and dim or warm light must not make it paler, yellower, redder, greyer or glossier. Only a soft local shadow and highlight may change it.
3. SHAPE: same silhouette, proportions, thickness and number of parts. For every leg, support, arm, root, strap or trim keep where it forks or joins, how many there are, how thick, and which way each goes. Never simplify a forked, curved or organic part into a plain column, pillar or stump; each part is one continuous piece, not a detached blob.
4. SURFACE: same material, grain or pattern and finish sheen. Parts made of the same material share one color: do not lighten, darken or add shine to one of them, and add no scratches, stains or wear.
5. FIT: place it at true scale with the perspective, contact shadows and occlusion of image 1. Feet touch the floor (sinking slightly into a rug); match image 1's exposure and noise locally on the product.
6. LIMITS: add or remove no part, prop, person, text or logo. A part hidden in image $ProductIndex stays plausible and consistent with its visible side; do not invent extra parts.
7. CHECK before finishing: compare the result with image $ProductIndex on shape, number of parts, color and sheen, and correct any difference.
"@
}
