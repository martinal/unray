// Fragment shader for the Unray project implementing
// variations of View Independent Cell Projection


// precision highp float;
// precision highp int;
// precision highp sampler2D;
// precision highp usampler2D;


// Using webpack-glsl-loader to copy in shared code
@import ./inverse;
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

#ifdef ENABLE_CELL_ORDERING
#define ENABLE_CELL_UV 1
#endif

#ifdef ENABLE_PERSPECTIVE_PROJECTION
#define ENABLE_COORDINATES 1
#endif

#ifdef ENABLE_EMISSION_BACK
#define ENABLE_EMISSION 1
#define ENABLE_DEPTH 1
#define ENABLE_JACOBIAN_INVERSE 1
#define ENABLE_VIEW_DIRECTION 1
#endif

#ifdef ENABLE_DENSITY_BACK
#define ENABLE_DENSITY 1
#define ENABLE_DEPTH 1
#define ENABLE_JACOBIAN_INVERSE 1
#define ENABLE_VIEW_DIRECTION 1
#endif

#ifdef ENABLE_DENSITY
#define ENABLE_VERTEX_UV 1
#endif

#ifdef ENABLE_EMISSION
#define ENABLE_VERTEX_UV 1
#endif

#ifdef ENABLE_JACOBIAN_INVERSE
#define ENABLE_COORDINATES 1
#endif

#ifdef ENABLE_COORDINATES
#define ENABLE_VERTEX_UV 1
#endif


// Time uniforms
uniform float u_time;
uniform vec4 u_oscillators;

// Custom camera uniforms
uniform vec3 u_view_direction;

// Input data uniforms
uniform vec3 u_constant_color;
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
varying vec3 v_view_direction; // flat
#ifdef ENABLE_DEPTH
varying vec4 v_ray_lengths;
#endif
#ifdef ENABLE_DENSITY
varying float v_density;
#endif
#ifdef ENABLE_EMISSION
varying float v_emission;
#endif
#ifdef ENABLE_DENSITY_BACK
varying float v_density_gradient; // FIXME: flat
#endif
#ifdef ENABLE_EMISSION_BACK
varying float v_emission_gradient; // flat
#endif

void main()
{
    // We need the view direction below
#ifdef ENABLE_PERSPECTIVE_PROJECTION
    //vec3 view_direction = normalize(v_view_direction);
    vec3 view_direction = normalize(v_model_position - cameraPosition);
#else
    vec3 view_direction = u_view_direction;
#endif


#ifdef ENABLE_DEPTH
    float depth = smallest_positive(v_ray_lengths);
#endif


    // Map components of values from [range.x, range.y] to [0, 1],
    // optimized by expecting
    //    range.w == 1.0 / (range.x - range.y) or 1 if range.x == range.y

#ifdef ENABLE_DENSITY
    float mapped_density = (v_density - u_density_range.x) * u_density_range.w;
    float evaluated_density = texture2D(t_density_lut, vec2(mapped_density, 0.5)).a;
#endif

#ifdef ENABLE_EMISSION
    float mapped_emission = (v_emission - u_emission_range.x) * u_emission_range.w;
    vec3 evaluated_color = texture2D(t_emission_lut, vec2(mapped_emission, 0.5)).xyz;
#endif

#ifdef ENABLE_DENSITY_BACK
    // TODO: With constant view direction,
    //    dot(v_density_gradient, view_direction)
    // is also constant and can be made a flat varying
    float density_back = v_density + depth * dot(v_density_gradient, view_direction);
    float mapped_density_back = (density_back - u_density_range.x) * u_density_range.w;
    float evaluated_density_back = texture2D(t_density_lut, vec2(mapped_density_back, 0.5)).a;
#endif

#ifdef ENABLE_EMISSION_BACK
    float emission_back = v_emission + depth * dot(v_emission_gradient, view_direction);
    float mapped_emission_back = (emission_back - u_emission_range.x) * u_emission_range.w;
    vec3 evaluated_color_back = texture2D(t_emission_lut, vec2(mapped_emission_back, 0.5)).xyz;
#endif


    // Note: Each model here defines vec3 C and float a inside the ifdefs,
    // which makes the compiler check that we define them once and only once.

    // TODO: Step through each model with some data and check. See CHECKME below.


#ifdef ENABLE_SURFACE_MODEL
    // TODO: Could add some light model for the surface shading here
    #if defined(ENABLE_EMISSION)
    vec3 C = evaluated_color;  // CHECKME
    #elif defined(ENABLE_DENSITY)
    vec3 C = evaluated_density * u_constant_color;  // CHECKME
    #else
    vec3 C = u_constant_color;  // CHECKME
    #endif
    // Always opaque
    float a = 1.0;
#endif


#ifdef ENABLE_SURFACE_DERIVATIVE_MODEL
    // TODO: Could we do something interesting with the gradient below the surface?
    // The gradient is unbounded, needs some mapping to [0,1].
    // Can use de/dv (below) or v_emission_gradient (or same for density)
    // float emission_view_derivative = (emission - emission_back) / depth;
#endif


#ifdef ENABLE_XRAY_MODEL
    #if defined(ENABLE_EMISSION)
    vec3 C = evaluated_color;  // CHECKME
    float a = 1.0;
    #elif defined(ENABLE_DENSITY)
    vec3 C = evaluated_density * u_constant_color;  // CHECKME
    float a = 1.0;
    #else
    #error "Xray model needs emission or density."
    #endif
#endif


#ifdef ENABLE_MAX_MODEL
    // TODO: This can also be done without the LUT,
    // using mapped_foo instead of evaluated_foo

    // Define color
    #if defined(ENABLE_EMISSION_BACK)
    vec3 C = max(evaluated_emission, evaluated_emission_back);  // CHECKME
    #elif defined(ENABLE_EMISSION)
    vec3 C = evaluated_emission;  // CHECKME
    #elif defined(ENABLE_DENSITY_BACK)
    vec3 C = u_constant_color * max(evaluated_density, evaluated_density_back);  // CHECKME
    #elif defined(ENABLE_DENSITY)
    vec3 C = u_constant_color * evaluated_density;  // CHECKME
    #else
    #error "Max model needs emission or density."
    #endif

    // TODO: Consider opacity computation and blend mode together.
    float a = 1.0;
#endif


    // Record result. Note that this will fail to compile
    // if C and a are not defined correctly above, providing a
    // small but significant safeguard towards errors in the
    // ifdef landscape above.
    gl_FragColor = vec4(C, a);


    // DEBUGGING:
    // gl_FragColor = vec4(1.0, 1.0, 1.0, 1.0);
    // gl_FragColor = vec4(u_constant_color, 1.0);
    // gl_FragColor = vec4(u_constant_color, a);
    // gl_FragColor = vec4(0.0, 0.0, 1.0, a);
}