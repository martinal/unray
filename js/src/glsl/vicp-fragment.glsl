// Fragment shader for the Unray project implementing
// variations of View Independent Cell Projection


// precision highp float;
// precision highp int;
// precision highp sampler2D;
// precision highp usampler2D;

// Added by three.js:
// #extension GL_OES_standard_derivatives : enable

// Using webpack-glsl-loader to copy in shared code
@import ./utils/inverse;
@import ./utils/getitem;
@import ./utils/sorted;
@import ./utils/depth;
@import ./vicp-lib;


/* Uniforms added by three.js, see
https://threejs.org/docs/index.html#api/renderers/webgl/WebGLProgram

uniform mat4 viewMatrix;
uniform vec3 cameraPosition;
*/


// Crude dependency graph for ENABLE_FOO code blocks.
// It's useful to share this between the vertex and fragment shader,
// so if something needs to be toggled separately in those there
// needs to be separate define names.

#ifdef ENABLE_XRAY_MODEL
#define ENABLE_DEPTH 1
#endif

#ifdef ENABLE_SURFACE_DEPTH_MODEL
#define ENABLE_DEPTH 1
#endif

#ifdef ENABLE_WIREFRAME
#define ENABLE_BARYCENTRIC_DERIVATIVES 1
#endif

#ifdef ENABLE_EMISSION_BACK
#define ENABLE_EMISSION 1
#define ENABLE_DEPTH 1
#define ENABLE_VIEW_DIRECTION 1
#endif

#ifdef ENABLE_DENSITY_BACK
#define ENABLE_DENSITY 1
#define ENABLE_DEPTH 1
#define ENABLE_VIEW_DIRECTION 1
#endif

#ifdef ENABLE_DENSITY
#endif

#ifdef ENABLE_EMISSION
#endif

#ifdef ENABLE_DEPTH
#define ENABLE_BARYCENTRIC_DERIVATIVES 1
#endif

#ifdef ENABLE_BARYCENTRIC_DERIVATIVES
#define ENABLE_BARYCENTRIC_COORDINATES 1
#endif


// Time uniforms
uniform float u_time;
uniform vec4 u_oscillators;


// Custom camera uniforms
#ifdef ENABLE_PERSPECTIVE_PROJECTION
#else
uniform vec3 u_view_direction;
#endif


// Input data uniforms
uniform vec3 u_constant_color;

#ifdef ENABLE_WIREFRAME
uniform vec3 u_wireframe_color;
uniform float u_wireframe_size;
#endif

#ifdef ENABLE_ISOSURFACE_MODEL
uniform vec2 u_isorange;
#endif

#if defined(ENABLE_XRAY_MODEL) || defined(ENABLE_VOLUME_MODEL)
uniform float u_particle_area;
#endif

// #ifdef ENABLE_CELL_INDICATORS
// uniform int u_cell_indicator_value;
// #endif
#ifdef ENABLE_DENSITY
uniform vec4 u_density_range;
#endif
#ifdef ENABLE_EMISSION
uniform vec4 u_emission_range;
#endif


// LUT textures
#ifdef ENABLE_DENSITY
uniform sampler2D t_density_lut;
#endif
#ifdef ENABLE_EMISSION
uniform sampler2D t_emission_lut;
#endif


// Varyings
varying vec3 v_model_position;


#ifdef ENABLE_BARYCENTRIC_COORDINATES
varying vec4 v_barycentric_coordinates;
#endif

// #ifdef ENABLE_CELL_INDICATORS
// varying float v_cell_indicator;                // want int or float, webgl2 required for flat keyword
// #endif

#ifdef ENABLE_DEPTH
varying float v_max_depth;               // webgl2 required for flat keyword
varying vec4 v_facing;                   // webgl2 required for flat keyword
#ifdef ENABLE_PERSPECTIVE_PROJECTION
varying mat4 v_planes;                   // webgl2 required for flat keyword
#else
varying vec4 v_ray_lengths;
#endif
#endif

#ifdef ENABLE_DENSITY
varying float v_density;
#endif
#ifdef ENABLE_EMISSION
varying float v_emission;
#endif

#ifdef ENABLE_DENSITY_BACK
varying vec3 v_density_gradient;  // webgl2 required for flat keyword
#endif
#ifdef ENABLE_EMISSION_BACK
varying vec3 v_emission_gradient;  // webgl2 required for flat keyword
#endif


void main()
{
    // TODO: See vertex shader for cell indicator plan
    // TODO: Handle facet indicators
// #ifdef ENABLE_CELL_INDICATORS
//     // Round to get the exact integer because fragment shader
//     // doesn't interpolate constant integer valued floats accurately
//     int cell_indicator = int(v_cell_indicator + 0.5);
//     // TODO: Use texture lookup with nearest interpolation to get
//     // color and discard-or-not (a=0|1) for a range of indicator values
//     if (cell_indicator != u_cell_indicator_value) {
//         discard;
//     }
// #endif


// #ifdef ENABLE_PERSPECTIVE_PROJECTION
//     vec3 position = v_model_position / gl_FragCoord.w;
// #else
    vec3 position = v_model_position;
// #endif


    // We need the view direction below
#ifdef ENABLE_PERSPECTIVE_PROJECTION
    vec3 view_direction = normalize(position - cameraPosition);
#else
    vec3 view_direction = u_view_direction;
#endif


#ifdef ENABLE_BARYCENTRIC_DERIVATIVES
    // These variables estimate the screen space resolution
    // for each barycentric coordinate component, useful for
    // determining whether bc is "close to" 0.0 or 1.0
    // vec4 bc_x = dFdx(v_barycentric_coordinates);
    // vec4 bc_y = dFdy(v_barycentric_coordinates);
    // vec4 bc_l1 = max(abs(bc_x), abs(bc_y));
    vec4 bc_width = fwidth(v_barycentric_coordinates);
    // vec4 bc_min = min(abs(bc_x), abs(bc_y));

#endif


#ifdef ENABLE_DEPTH

// #define ENABLE_FACING_IS_COS_ANGLE 1
#ifdef ENABLE_FACING_IS_COS_ANGLE
    bvec4 is_back_face = lessThan(v_facing, vec4());
#else
    bvec4 is_back_face = lessThan(v_facing, vec4(-0.5));
    // bvec4 is_orthogonal_face = lessThan(abs(v_facing), vec4(0.5));
#endif

    // Never accept negative ray lengths
    // bvec4 is_on_face = bvec4(false);

    // Accept negative ray lengths on backside edges, stricter resolution dependent check
    bvec4 is_on_face = lessThanEqual(v_barycentric_coordinates, vec4(0.0));

    // Accept negative ray lengths on backside edges, stricter resolution dependent check
    // bvec4 is_on_face = lessThanEqual(v_barycentric_coordinates, 0.5*bc_width);

    // Accept negative ray lengths on backside edges, resolution dependent check
    // bvec4 is_on_face = lessThan(v_barycentric_coordinates, bc_width);

// Case: is_back_face[i] && is_on_face[i] && !is_outside_face[i] && ray_lengths[i] < 0.0
// facing = -1  i.e. not_any(greaterThanEqual(cos_angles, vec3(0.0)))
// bc < bc_width
// !(bc < 0)  i.e. bc >= 0
// ray < 0
// To avoid artifacts from this case, the only solution must
// be to disregard it and get depth from another backface?


#ifdef ENABLE_PERSPECTIVE_PROJECTION
    vec4 ray_lengths = vec4(-1.0);
    for (int i = 0; i < 4; ++i) {
        // Only need lengths for back faces
        if (is_back_face[i]) {
            vec3 n = v_planes[i].xyz;
            float p = v_planes[i].w;
            ray_lengths[i] = (p - dot(n, position)) / dot(n, view_direction);
        }
    }
    // for (int i = 0; i < 4; ++i) {
    // {
    //     // Check if exit point is inside tetrahedron
    //     vec3 exit_point = position + ray_lengths[i] * view_direction;
    //     for (int j = 0; j < 4; ++j) {
    //         vec3 nj = v_planes[j].xyz;
    //         float pj = v_planes[j].w;
    //         if (pj - dot(nj, position) <= 1e-3) {
    //             ray_lengths[i] = 0.0;
    //         }
    //     }
    // }
#else
    vec4 ray_lengths = v_ray_lengths;
#endif

    // TODO: Clean up arguments depending on final solution
    float depth = compute_depth2(ray_lengths, is_back_face, is_on_face, v_max_depth);
    // float depth = compute_depth(ray_lengths, is_back_face, is_on_face, v_max_depth);
#endif


    // Map components of values from [range.x, range.y] to [0, 1],
    // optimized by expecting
    //    range.w == 1.0 / (range.x - range.y) or 1 if range.x == range.y

    // FIXME: Clamp scaled_density and scaled_emission to [0,1],
    // or just allow the texture sampler to deal with that?

#ifdef ENABLE_DENSITY
    float scaled_density = (v_density - u_density_range.x) * u_density_range.w;
    float mapped_density = texture2D(t_density_lut, vec2(scaled_density, 0.5)).a;
#endif

#ifdef ENABLE_EMISSION
    float scaled_emission = (v_emission - u_emission_range.x) * u_emission_range.w;
    vec3 mapped_emission = texture2D(t_emission_lut, vec2(scaled_emission, 0.5)).xyz;
#endif

#ifdef ENABLE_DENSITY_BACK
    // TODO: With constant view direction,
    //    dot(v_density_gradient, view_direction)
    // is also constant and can be made a flat varying
    float density_back = v_density + depth * dot(v_density_gradient, view_direction);
    float scaled_density_back = (density_back - u_density_range.x) * u_density_range.w;
    float mapped_density_back = texture2D(t_density_lut, vec2(scaled_density_back, 0.5)).a;
#endif

#ifdef ENABLE_EMISSION_BACK
    float emission_back = v_emission + depth * dot(v_emission_gradient, view_direction);
    float scaled_emission_back = (emission_back - u_emission_range.x) * u_emission_range.w;
    vec3 mapped_emission_back = texture2D(t_emission_lut, vec2(scaled_emission_back, 0.5)).xyz;
#endif


    // Note: Each model here defines vec3 C and float a inside the ifdefs,
    // which makes the compiler check that we define them once and only once.

    // TODO: Step through each model with some data and check. See CHECKME below.

    // TODO: Could map functions to different color channels:
    //       hue, saturation, luminance, noise texture intensity


#ifdef ENABLE_DEBUG_MODEL
    vec3 C = vec3(1.0, 0.5, 0.5);
    float a = 1.0;
#endif


#ifdef ENABLE_SURFACE_MODEL
    // TODO: Could add some light model for the surface shading here?

    // vec3 surface_normal = normalize(v_density_gradient);
    // vec3 surface_normal = normalize(v_emission_gradient);

    #if defined(ENABLE_EMISSION)
    vec3 C = mapped_emission;  // CHECKME
    #elif defined(ENABLE_DENSITY)
    vec3 C = mapped_density * u_constant_color;  // CHECKME
    #else
    vec3 C = u_constant_color;  // CHECKME
    #endif

    // Always opaque
    float a = 1.0;
#endif


#ifdef ENABLE_SURFACE_DEPTH_MODEL
    // This is primarily a debugging technique

    // Scaling depth to [0,1], deepest is black, shallow is white
    // vec3 C = vec3(1.0 - depth/v_max_depth);

    // Deepest is green, shallow is red
    vec3 C = mix(vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), depth/v_max_depth);

    // Always opaque
    float a = 1.0;
#endif


    // I'm sure this can be done more elegantly but the endgoal
    // is texture lookups to support arbitrary numbers of isovalues
#ifdef ENABLE_ISOSURFACE_MODEL
    // TODO: Could add some light model for the surface shading here?

    vec2 isorange = u_isorange;

    #if defined(ENABLE_DENSITY)
    compile_error();  // Isosurface only implemented for emission for now
    #elif defined(ENABLE_EMISSION_BACK)
    float front = v_emission;
    float back = emission_back;
    #elif defined(ENABLE_EMISSION)
    float front = v_emission;
    float back = v_emission;
    #else
    compile_error();  // Isosurface needs emission
    #endif

    // vec3 surface_normal = normalize(v_emission_gradient);

    bool front_in_range = isorange.x <= front && front <= isorange.y;
    bool back_in_range = isorange.x <= back && back <= isorange.y;

    // If values are not in isorange, discard this fragment
    if (!(front_in_range || back_in_range)) {
        discard;
    }

    // Select isorange value closest to camera
    float value;
    if (front_in_range) {
        value = front;
    } else if (front > back) {
        value = isorange.y;
    } else {
        value = isorange.x;
    }

    // Map value through color lut
    // TODO: Using emission lut here for now, what to do here is question of how to configure encoding parameters
    float scaled_value = (value - u_emission_range.x) * u_emission_range.w;
    vec3 C = texture2D(t_emission_lut, vec2(scaled_value, 0.5)).xyz;        

    // Opaque since isosurface is contained in [back, front]
    float a = 1.0;
#endif


#ifdef ENABLE_SURFACE_DERIVATIVE_MODEL
    // TODO: Could we do something interesting with the gradient below the surface.
    // The gradient is unbounded, needs some mapping to [0,1].
    // Can use de/dv (below) or v_emission_gradient (or same for density)
    float emission_view_derivative = (emission - emission_back) / depth;
    float gamma = emission_view_derivative / (emission_view_derivative + 1.0);

    vec3 C = u_constant_color * gamma;

    // Always opaque
    float a = 1.0;
#endif


#ifdef ENABLE_XRAY_MODEL
    #if defined(ENABLE_EMISSION)
    compile_error();  // Xray model does not accept emission, only density
    #elif defined(ENABLE_DENSITY_UNIFORM)
    float rho = u_density;  // TODO: Add this
    #elif defined(ENABLE_DENSITY_INTEGRATED)
    // TODO: Preintegrated texture of integrated density from front to back value
    #elif defined(ENABLE_DENSITY_BACK) // TODO: Rename ENABLE_DENSITY_BACK -> ENABLE_DENSITY_LINEAR
    // This is exact assuming rho linear along a ray segment
    float rho = mix(mapped_density, mapped_density_back, 0.5);
    #elif defined(ENABLE_DENSITY)  // TODO: Use ENABLE_DENSITY_CONSTANT
    // This is exact for rho constant along a ray segment
    float rho = mapped_density;
    #else
    compile_error();  // Xray model needs density and density only
    #endif

    // rho = 0.1; // DEBUGGING FIXME REMOVE TODO

    // DEBUGGING: Add some oscillation to density
    float area = u_particle_area;
    // area *= (2.0 + u_oscillators[1]) / (3.0);

    // Compute transparency (NB! this is 1-opacity)
    float a = exp(-depth * area * rho);  // CHECKME
    // a = clamp(a, 0.0, 1.0);


    // a = 0.1; // depth / v_max_depth;  // TODO DEBUGGING FIXME


    // This must be zero for no emission to occur, i.e.
    // all color comes from the background and is attenuated by 1-a
    vec3 C = vec3(0.0);  // CHECKME

    // TODO: Test smallest_positive more
    // C.rgb = v_ray_lengths.xyz;  // These are nonzero

    // C.r = 0.0; // smallest_positive(vec4(0.0, 0.0, 0.0, 0.0));
    // C.g = 1.0; // smallest_positive(vec4(1.0, 1.0, 1.0, 1.0));
    // C.b = 1.0; // smallest_positive(vec4(-1.0, 0.0, 1.0, 0.0));

    // C.r = smallest_positive(vec4(-1.0, 1.0, 0.0, 0.0));
    // a = 0.0;
#endif


#ifdef ENABLE_MAX_MODEL
    // TODO: This can also be done without the LUT,
    // using scaled_foo instead of mapped_foo

    // Define color
    #if defined(ENABLE_EMISSION) && defined(ENABLE_DENSITY)
    compile_error();  // Only emission OR density allowed.
    #elif defined(ENABLE_EMISSION_BACK)
    vec3 C = max(mapped_emission, mapped_emission_back);  // CHECKME
    #elif defined(ENABLE_EMISSION)
    vec3 C = mapped_emission;  // CHECKME
    #elif defined(ENABLE_DENSITY_BACK)
    vec3 C = u_constant_color * max(mapped_density, mapped_density_back);  // CHECKME
    #elif defined(ENABLE_DENSITY)
    vec3 C = u_constant_color * mapped_density;  // CHECKME
    #else
    compile_error();  // Max model needs emission or density
    #endif

    // Opacity is unused for this mode
    float a = 1.0;
#endif


#ifdef ENABLE_MIN_MODEL
    // TODO: This can also be done without the LUT,
    // using scaled_foo instead of mapped_foo

    // Define color
    #if defined(ENABLE_EMISSION) && defined(ENABLE_DENSITY)
    compile_error();  // Only emission OR density allowed.
    #elif defined(ENABLE_EMISSION_BACK)
    vec3 C = min(mapped_emission, mapped_emission_back);  // CHECKME
    #elif defined(ENABLE_EMISSION)
    vec3 C = mapped_emission;  // CHECKME
    #elif defined(ENABLE_DENSITY_BACK)
    vec3 C = u_constant_color * min(mapped_density, mapped_density_back);  // CHECKME
    #elif defined(ENABLE_DENSITY)
    vec3 C = u_constant_color * mapped_density;  // CHECKME
    #else
    compile_error();  // Max model needs emission or density
    #endif

    // Opacity is unused for this mode
    float a = 1.0;
#endif


#ifdef ENABLE_VOLUME_MODEL
    //#if defined(ENABLE_DENSITY_BACK) && defined(ENABLE_EMISSION_BACK)
    // TODO: Implement Moreland partial pre-integration

    #if defined(ENABLE_DENSITY_BACK)
    // TODO: Currently only using average density, more accurate options exist.
    float rho = mix(mapped_density, mapped_density_back, 0.5); // CHECKME
    #elif defined(ENABLE_DENSITY)
    float rho = mapped_density; // CHECKME
    #else
    compile_error();  // Volume model requires density
    #endif

    #if defined(ENABLE_EMISSION_BACK)
    // TODO: Currently only using average color, more accurate options exist.
    vec3 L = mix(mapped_emission, mapped_emission_back, 0.5); // CHECKME
    #elif defined(ENABLE_EMISSION)
    vec3 L = mapped_emission; // CHECKME
    #else
    compile_error();  // Volume model requires emission
    #endif

    // Evaluate ray integral, use in combination
    // with blend equation: RGB_src * A_dst + RGB_dst
    float a = 1.0 - exp(-depth * u_particle_area * rho); // CHECKME
    vec3 C = a * L;
#endif


#ifdef ENABLE_WIREFRAME
    // Compute a measure of closeness to edge in [0, 1],
    // using partial derivatives of barycentric coordinates
    // in window space to ensure edge size is large enough
    // for far away edges.
    vec4 edge_closeness = smoothstep(vec4(0.0), max(bc_width, u_wireframe_size), v_barycentric_coordinates);

    // Pick the second smallest edge closeness and square it
    vec4 sorted_edge_closeness = sorted(edge_closeness);
    float edge_factor = abs(sorted_edge_closeness[0]) + abs(sorted_edge_closeness[1]);

    // Mix edge color into background
    C = mix(u_wireframe_color, C, edge_factor * edge_factor);

    // Otherwise keep computed color C.
    // TODO: Cheaper to don't compute C first if it's to be discarded,
    //       setup ifdefs to make that part flow right
#endif


    // TODO: Untested draft:
#ifdef ENABLE_FACET_INDICATORS
    // TODO: Use texture lookup to find color and .a=0|1 discard status
    // ivec4 facet_indicators = ivec4(v_facet_indicators);
    ivec4 facet_indicators = ivec4(0, 1, 0, 1);
    int facet_indicator_value = 0;

    float eps = 1e-2;  // TODO: Configurable tolerance
    for (int i = 0; i < 4; ++i) {
        if (v_barycentric_coordinates[i] < eps) {
            if (facet_indicators[i] == facet_indicator_value) {
                discard;
            }
        }
    }
#endif


    // Debugging
    // if (gl_FrontFacing) {
    //     C.r = 0.0;
    // } else {
    //     C.r = 1.0;
    // }

    // DEBUGGING:
    // a = 1.0;
    // C = vec3(1.0);
    // C = u_constant_color;
    // C = vec3(0.0, 0.0, 1.0);


    // Debugging
    // if (depth > 0.3 * v_max_depth) {
    // if (depth > v_max_depth * (1.0 + 1e-6)) {
    //     C.r = 1.0;
    //     // C.b = 0.0;
    // // } else if (depth < 0.1 * v_max_depth) {
    // //     C.r = 0.0;
    // //     C.b = 1.0;
    // } else {
    //     C.r = 0.0;
    //     // C.b = 0.0;
    // }

    // Debugging
    // a = 1.0;
    // vec4 q = 0.5 * (vec4(1.0) + v_facing);
    // vec3 r = vec3(1.0, 0.0, 0.0);
    // vec3 g = vec3(0.0, 1.0, 0.0);
    // vec3 b = vec3(0.0, 0.0, 1.0);
    // vec3 y = vec3(0.0, 1.0, 1.0);
    // C = vec3(0.0);
    // // C = vec3(max(v_facing), length(v_facing + abs(v_facing)) / 4.0, min(v_facing));
    // // q[i] = 0 if facing[i] = -1,  q[i] = 1 if facing[i] = +1,  length(q) == sqrt(number of +1 faces)
    // float q2 = length(q)*length(q);  // number of +1 faces
    // q2 = 4.0 - q2; // now q2 = number of -1 faces
    // // looks like -1 faces point toward camera
    // if (q2 < 0.1)
    //     C = vec3(0);
    // else if (q2 < 1.1)
    //     C = r;
    // else if (q2 < 2.1)
    //     C = g;
    // else if (q2 < 3.1)
    //     C = b;
    // else
    //     C = vec3(1.0);

    // C += maxv(q) * r;
    // C += minv(q) * b;
    // C += length(q) / 3.0 * g;
    // C.r = length(v_facing + abs(v_facing)) / 2.0;

    // C = 0.5 * (q.r * r + q.g * g + q.b * b + q.a * y);
    // C = vec3(1.0, 0.0, 0.0);
    // C = vec3(0.0, 0.0, 0.0);

    // Debugging
    // a = 1.0;
    // C = vec3(0.0);

    // C.r = 1.0;
    // for (int i = 0; i < 4; ++i) {
    //     if (v_facing[i] < 0.0 && ray_lengths[i] > 0.0) {
    //         C.r = min(C.r, ray_lengths[i] / v_max_depth);
    //     }
    // }

    // Highlight edges shared with a backface where ray length is negative
    // for (int i = 0; i < 4; ++i) {
    //     // if (is_back_face[i] && is_on_face[i] && ray_lengths[i] < 0.0) {
    //     if (is_back_face[i] && is_on_face[i]) {
    //         C.r = 1.0;
    //     }
    // }


    // Highlight edges // TODO: Can probably adjust this with smoothstep as wireframe 
    // int face_count = 0;
    // for (int i = 0; i < 4; ++i) {
    //     if (is_on_face[i]) {
    //         ++face_count;
    //     }
    // }
    // if (face_count > 1) {
    //     C = vec3(1.0);
    //     a = 1.0;
    // }


    // Highlight backface edges
    // bool red = false;
    // for (int i = 0; i < 4; ++i) {
    //     if (is_back_face[i] && is_on_face[i]) {
    //         red = true;
    //         break;
    //     }
    // }
    // if (red) { C.r = 1.0; } else { C.b = 1.0; }


    // Highlight edges shared with a backface where ray length is negative
    // for (int i = 0; i < 4; ++i) {
    //     if (is_orthogonal_face[i] && is_on_face[i]) {
    //         if (ray_lengths[i] < 0.0) {
    //             C.r = 1.0;
    //         } else {
    //             C.g = 1.0;
    //         }
    //         a = 1.0;
    //     }
    // }

    // bvec4 is_back_face
    // bvec4 is_on_face
    bvec4 is_outside_face = lessThan(v_barycentric_coordinates, vec4(0.0));  // TODO: Use this in depth computation
    for (int i = 0; i < 4; ++i) {

        // Select edges shared with a backface
        if (is_back_face[i] && is_on_face[i]) {
            // C = vec3(0.0);  a = 1.0;

            // Edges outside the face happens all over
            // if (is_outside_face[i]) {
            //     C.r = 1.0;
            //     a = 1.0;
            // }

            // // When outside the face, negative ray lengths occur routinely
            // if (ray_lengths[i] < 0.0 && is_outside_face[i]) {
            //     C.r = 1.0;
            //     a = 1.0;
            // }

            // In fact, when outside the face, non-negative ray lengths are unlikely (but do occur)
            // if (ray_lengths[i] >= 0.0 && is_outside_face[i]) {
            //     C.b = 1.0;
            //     a = 1.0;
            // }

            // When not outside the face, negative ray lengths also happens quite often
            // Could this be cases that should not be classified as backside?
            if (ray_lengths[i] < 0.0 && !is_outside_face[i]) {
                C.r = 1.0;
                a = 1.0;
            }

    //         // else { a = 0.0; }
    //         // NB! No case for non-negative ray length AND barycentric coordinate simultaneously.
        }
    }

    // float tmp = 1.0;
    // for (int i = 0; i < 4; ++i) {
        // With v_facing[i] < 0.0,  i is a backface, but ray_lengths can still be negative
        // if (v_facing[i] < 0.0 && ray_lengths[i] < 0.0) {
        //     C.r = 1.0;
        // }

        // if (v_facing[i] < 0.0 && ray_lengths[i] > 0.0) {
        //     C.b += 0.33;
        // }
        // if (v_facing[i] < 0.0 && ray_lengths[i] > v_max_depth) {
        //     C.r += 0.33;
        // }
        // if (v_facing[i] < 0.0 && ray_lengths[i] < 0.0) {
        //     C.g += 0.33;
        // }
        // With  v_facing[i] > 0.0,  ray_lengths[i] is noisy around 0,  naturally.
        // if (v_facing[i] > 0.0 && ray_lengths[i] < 0.0) {
        //     C.g = 1.0;
        // }
        // if (v_facing[i] > 0.0 && ray_lengths[i] > 1e-2*v_max_depth) {
        //     // tmp = 1.0;
        //     C.g = 1.0;
        // }
    // }
    // C *= tmp;

    // Record result. Note that this will fail to compile
    // if C and a are not defined correctly above, providing a
    // small but significant safeguard towards errors in the
    // ifdef landscape above.
    gl_FragColor = vec4(C, a);
}
