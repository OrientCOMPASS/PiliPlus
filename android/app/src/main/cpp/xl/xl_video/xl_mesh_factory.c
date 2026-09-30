//
// Created by 晓龙同学 on 2017/4/12.
//

#include <malloc.h>
#include <string.h>
#include "xl_mesh_factory.h"
#include "math.h"

// =====================================================================================
// 【PiliPlus 扩展】球面网格的投影参数化
//
// 上游的 get_ball_mesh() 只能生成"整幅 360° 单目等距柱状"网格：经度固定 0..360、
// u 固定 0..1、v 固定 0..1。而实际片源还有
//   · 覆盖角 180°（VR180）——网格经度只能张 ±90°；
//   · 左右(SBS) / 上下(TB) 立体布局——单眼只占贴图的一半（u∈[0,.5] 或 v∈[.5,1]）。
// 这两件事的差别**只在网格的经度范围和 uv 映射区间**，顶点/索引的生成方式完全一样，
// 所以把它们参数化，默认值与上游逐字一致（coverage=360, u=[0,1], v=[0,1]），
// 不调用 xl_mesh_set_projection() 时上游行为分毫不变。
//
// 与上游唯一的语义差别：经度起点从"i=0 落在 +X 轴"改成"贴图 u 的中点落在镜头正前方(-Z)"。
// 上游那个起点是任意的（360 片源开机看到哪一段全凭运气），而 180° 片源**必须**让画面中心
// 朝前，否则开机看到的是网格边缘的接缝。
// =====================================================================================
static float s_coverage_deg = 360.0f;
static float s_u0 = 0.0f, s_u1 = 1.0f;
static float s_v0 = 0.0f, s_v1 = 1.0f;

void xl_mesh_set_projection(float coverage_deg, float u0, float u1, float v0, float v1) {
    if (coverage_deg < 1.0f) coverage_deg = 1.0f;
    if (coverage_deg > 360.0f) coverage_deg = 360.0f;
    s_coverage_deg = coverage_deg;
    s_u0 = u0;
    s_u1 = u1;
    s_v0 = v0;
    s_v1 = v1;
}

xl_mesh *get_ball_mesh() {
    xl_mesh *ball_mesh;
    ball_mesh = (xl_mesh *) malloc(sizeof(xl_mesh));
    memset(ball_mesh, 0, sizeof(xl_mesh));
    int i, j, jj;
    int step = 5;
    // 纬度仍按上游固定 180°/5° = 36 段（VR 片源的上下布局由 v 区间表达，不改纬度）。
    int lat_steps = 180 / step;
    // 经度段数按覆盖角走：360° → 72 段，180° → 36 段。
    int lon_steps = (int) (s_coverage_deg / step);
    if (lon_steps < 1) lon_steps = 1;
    int jstep = lon_steps + 1;
    float coverage = (float) lon_steps * step;
    // 270° 对应 -Z（相机视线方向，见 xl_model_ball.c 的 lookAt(0,0,eyez, 0,0,-1, ...)）。
    float lon_start = 270.0f - coverage * 0.5f;

    ball_mesh->ppLen = (lat_steps + 1) * (lon_steps + 1) * 3;
    ball_mesh->ttLen = (lat_steps + 1) * (lon_steps + 1) * 2;
    ball_mesh->indexLen = lon_steps * lat_steps * 6;
    ball_mesh->pp = (float *) malloc((size_t) (sizeof(float) * ball_mesh->ppLen));
    ball_mesh->tt = (float *) malloc((size_t) (sizeof(float) * ball_mesh->ttLen));
    ball_mesh->index = (unsigned int *) malloc(sizeof(unsigned int) * ball_mesh->indexLen);

    for (j = -90, jj = 90; j <= jj; j += step) {
        for (i = 0; i <= lon_steps; i++) {
            float lon = lon_start + (float) i * step;
            float sini = sinf(lon / 180.0f * (float) M_PI);
            float cosi = cosf(lon / 180.0f * (float) M_PI);
            float sinj = sinf((float) j / 180.0f * (float) M_PI);
            float cosj = cosf((float) j / 180.0f * (float) M_PI);
            float r = 1;
            float y = r * sinj;
            float x = r * cosj * cosi;
            float z = r * cosj * sini;
            *ball_mesh->pp++ = x;
            *ball_mesh->pp++ = y;
            *ball_mesh->pp++ = z;
            // uv 落在调用方指定的单眼区域内（默认 [0,1]×[0,1] == 上游行为）。
            *ball_mesh->tt++ = s_u0 + (s_u1 - s_u0) * ((float) i / (float) lon_steps);
            *ball_mesh->tt++ = s_v0 + (s_v1 - s_v0) * ((float) j / 90.0f / 2.0f + 0.5f);
        }
    }

    for (i = 0; i < lon_steps; ++i) {
        for (j = 0, jj = lat_steps; j < jj; j++) {
            *ball_mesh->index++ = (unsigned int) (j * jstep + i);
            *ball_mesh->index++ = (unsigned int) (j * jstep + i + 1);
            *ball_mesh->index++ = (unsigned int) ((j + 1) * jstep + i + 1);
            *ball_mesh->index++ = (unsigned int) (j * jstep + i);
            *ball_mesh->index++ = (unsigned int) ((j + 1) * jstep + i + 1);
            *ball_mesh->index++ = (unsigned int) ((j + 1) * jstep + i);
        }
    }
    ball_mesh->pp -= ball_mesh->ppLen;
    ball_mesh->tt -= ball_mesh->ttLen;
    ball_mesh->index -= ball_mesh->indexLen;
    return ball_mesh;
}

xl_mesh *get_rect_mesh() {
    xl_mesh *rect_mesh;
    rect_mesh = (xl_mesh *) malloc(sizeof(xl_mesh));
    memset(rect_mesh, 0, sizeof(xl_mesh));

    rect_mesh->ppLen = 12;
    rect_mesh->ttLen = 8;
    rect_mesh->indexLen = 6;
    rect_mesh->pp = (float *) malloc((size_t) (sizeof(float) * rect_mesh->ppLen));
    rect_mesh->tt = (float *) malloc((size_t) (sizeof(float) * rect_mesh->ttLen));
    rect_mesh->index = (unsigned int *) malloc(sizeof(unsigned int) * rect_mesh->indexLen);
    float pa[12] = {-1, 1, -0.1f, 1, 1, -0.1f, 1, -1, -0.1f, -1, -1, -0.1f};
    float ta[8] = {0, 1, 1, 1, 1, 0, 0, 0};
    unsigned int ia[6] = {0, 1, 2, 0, 2, 3};
    for (int i = 0; i < 12; ++i) {
        *rect_mesh->pp++ = pa[i];
    }
    for (int i = 0; i < 8; ++i) {
        *rect_mesh->tt++ = ta[i];
    }
    for (int i = 0; i < 6; ++i) {
        *rect_mesh->index++ = ia[i];
    }
    rect_mesh->pp -= rect_mesh->ppLen;
    rect_mesh->tt -= rect_mesh->ttLen;
    rect_mesh->index -= rect_mesh->indexLen;
    return rect_mesh;
}

xl_mesh *get_planet_mesh() {
    xl_mesh *planet_mesh;
    planet_mesh = (xl_mesh *) malloc(sizeof(xl_mesh));
    memset(planet_mesh, 0, sizeof(xl_mesh));
    int i, j, ii, jj;
    int step = 1;
    float sinj, cosj;
    int jstep = 360 / step + 1;
    planet_mesh->ppLen = (180 / step + 1) * (360 / step + 1) * 3;
    planet_mesh->ttLen = (180 / step + 1) * (360 / step + 1) * 2;
    planet_mesh->indexLen = (360 / step) * (180 / step) * 6;
    planet_mesh->pp = (float *) malloc((size_t) (sizeof(float) * planet_mesh->ppLen));
    planet_mesh->tt = (float *) malloc((size_t) (sizeof(float) * planet_mesh->ttLen));
    planet_mesh->index = (unsigned int *) malloc(sizeof(unsigned int) * planet_mesh->indexLen);

    for (i = 0, ii = 180; i <= ii; i += step) {
        for (j = 0, jj = 360; j <= jj; j += step) {
            sinj = sinf((float)j / 180.0f * (float)M_PI);
            cosj = cosf((float)j / 180.0f * (float)M_PI);
            *planet_mesh->pp++ = (float)i * cosj / 180.0f;
            *planet_mesh->pp++ = (float)i * sinj / 180.0f;
            *planet_mesh->pp++ = -1.0f;
            *planet_mesh->tt++ = 1.0f - (float)j / 360.0f;
            *planet_mesh->tt++ = (float)i / 180.0f;
        }
    }

    for (j = 0, jj = 180 / step; j < jj; ++j) {
        for (i = 0, ii = 360 / step; i < ii; ++i) {
            *planet_mesh->index++ = (unsigned int) (j * jstep + i);
            *planet_mesh->index++ = (unsigned int) ((j + 1) * jstep + i);
            *planet_mesh->index++ = (unsigned int) ((j + 1) * jstep + i + 1);

            *planet_mesh->index++ = (unsigned int) (j * jstep + i);
            *planet_mesh->index++ = (unsigned int) ((j + 1) * jstep + i + 1);
            *planet_mesh->index++ = (unsigned int) (j * jstep + i + 1);
        }
    }

    planet_mesh->pp -= planet_mesh->ppLen;
    planet_mesh->tt -= planet_mesh->ttLen;
    planet_mesh->index -= planet_mesh->indexLen;
    return planet_mesh;
}


static inline float distortionFactor(float radius) {
    int s_numberOfCoefficients = 2;
    static float _coefficients[2] = {0.441000015f, 0.156000003f};

    float result = 1.0f;
    float rFactor = 1.0f;
    float squaredRadius = radius * radius;
    for (int i = 0; i < s_numberOfCoefficients; i++) {
        rFactor *= squaredRadius;
        result += _coefficients[i] * rFactor;
    }
    return result;
}

static inline float distort(float radius){
    return radius * distortionFactor(radius);
}

static inline float blueDistortInverse(float radius) {
    float r0 = radius / 0.9f;
    float r = radius * 0.9f;
    float dr0 = radius - distort(r0);
    while (fabsf(r - r0) > 0.0001f) {
        float dr = radius - distort(r);
        float r2 = r - dr * ((r - r0) / (dr - dr0));
        r0 = r;
        r = r2;
        dr0 = dr;
    }
    return r;
}
static inline float clamp(float val, float min, float max)
{
    float temp = val > min ? val : min;
    return temp < max ? temp : max;
}

// eye : 0 left
//       1 right
xl_mesh * get_distortion_mesh(int eye){
    xl_mesh *distortion_mesh = (xl_mesh *) malloc(sizeof(xl_mesh));
    float xEyeOffsetScreen = 0.523064613f;
    float yEyeOffsetScreen = 0.80952388f;

    float viewportWidthTexture = 1.43138313f;
    float viewportHeightTexture = 1.51814604f;

    float viewportXTexture = 0;
    float viewportYTexture = 0;

    float textureWidth = 2.86276627f;
    float textureHeight = 1.51814604f;

    float xEyeOffsetTexture = 0.592283607f;
    float yEyeOffsetTexture = 0.839099586f;

    float screenWidth = 2.47470069f;
    float screenHeight = 1.39132345f;

    if (eye == 1) {
        xEyeOffsetScreen = 1.95163608f;
        viewportXTexture = 1.43138313f;
        xEyeOffsetTexture = 2.27048278f;
    }

    const int rows = 40;
    const int cols = 40;
//    float vertexData[rows * cols * 9];
    float * vertexData = malloc(sizeof(float) * rows * cols * 9);
    unsigned int vertexOffset = 0;
    const float vignetteSizeTanAngle = 0.05f;

    for (int row = 0; row < rows; row++) {
        for (int col = 0; col < cols; col++) {
            const float uTextureBlue = col / 39.0f * (viewportWidthTexture / textureWidth) + viewportXTexture / textureWidth;
            const float vTextureBlue = row / 39.0f * (viewportHeightTexture / textureHeight) + viewportYTexture / textureHeight;

            const float xTexture = uTextureBlue * textureWidth - xEyeOffsetTexture;
            const float yTexture = vTextureBlue * textureHeight - yEyeOffsetTexture;
            const float rTexture = sqrtf(xTexture * xTexture + yTexture * yTexture);

            const float textureToScreenBlue = (rTexture > 0.0f) ? blueDistortInverse(rTexture) / rTexture : 1.0f;

            const float xScreen = xTexture * textureToScreenBlue;
            const float yScreen = yTexture * textureToScreenBlue;

            const float uScreen = (xScreen + xEyeOffsetScreen) / screenWidth;
            const float vScreen = (yScreen + yEyeOffsetScreen) / screenHeight;
            const float rScreen = rTexture * textureToScreenBlue;

            const float screenToTextureGreen = (rScreen > 0.0f) ? distortionFactor(rScreen) : 1.0f;
            const float uTextureGreen = (xScreen * screenToTextureGreen + xEyeOffsetTexture) / textureWidth;
            const float vTextureGreen = (yScreen * screenToTextureGreen + yEyeOffsetTexture) / textureHeight;

            const float screenToTextureRed = (rScreen > 0.0f) ? distortionFactor(rScreen) : 1.0f;
            const float uTextureRed = (xScreen * screenToTextureRed + xEyeOffsetTexture) / textureWidth;
            const float vTextureRed = (yScreen * screenToTextureRed + yEyeOffsetTexture) / textureHeight;

            const float vignetteSizeTexture = vignetteSizeTanAngle / textureToScreenBlue;

            const float dxTexture = xTexture + xEyeOffsetTexture - clamp(xTexture + xEyeOffsetTexture,
                                                                         viewportXTexture + vignetteSizeTexture,
                                                                         viewportXTexture + viewportWidthTexture - vignetteSizeTexture);
            const float dyTexture = yTexture + yEyeOffsetTexture - clamp(yTexture + yEyeOffsetTexture,
                                                                         viewportYTexture + vignetteSizeTexture,
                                                                         viewportYTexture + viewportHeightTexture - vignetteSizeTexture);
            const float drTexture = sqrtf(dxTexture * dxTexture + dyTexture * dyTexture);

            float vignette = 1.0f - clamp(drTexture / vignetteSizeTexture, 0.0f, 1.0f);

            vertexData[(vertexOffset + 0)] = 2.0f * uScreen - 1.0f;
            vertexData[(vertexOffset + 1)] = 2.0f * vScreen - 1.0f;
            vertexData[(vertexOffset + 2)] = vignette;
            vertexData[(vertexOffset + 3)] = uTextureRed;
            vertexData[(vertexOffset + 4)] = vTextureRed;
            vertexData[(vertexOffset + 5)] = uTextureGreen;
            vertexData[(vertexOffset + 6)] = vTextureGreen;
            vertexData[(vertexOffset + 7)] = uTextureBlue;
            vertexData[(vertexOffset + 8)] = vTextureBlue;

            vertexOffset += 9;
        }
    }


    int index_count = (rows - 1) * (cols - 1) * 6;
    unsigned int * indexData = malloc(sizeof(unsigned int) * index_count);
    for(int i = 0; i < rows - 1; ++i){
        for(int j = 0; j < cols - 1; ++j){
            *indexData++ = (unsigned int) (j * cols + i);
            *indexData++ = (unsigned int) ((j + 1) * cols + i);
            *indexData++ = (unsigned int) ((j + 1) * cols + i + 1);

            *indexData++ = (unsigned int) (j * cols + i);
            *indexData++ = (unsigned int) ((j + 1) * cols + i + 1);
            *indexData++ = (unsigned int) (j * cols + i + 1);
        }
    }
    indexData -= index_count;

    distortion_mesh->pp = vertexData;
    distortion_mesh->ppLen = rows * cols * 9;
    distortion_mesh->tt = NULL;
    distortion_mesh->index = indexData;
    distortion_mesh->indexLen = index_count;
    return distortion_mesh;
}


void free_mesh(xl_mesh *p) {
    if (p != NULL) {
        if (p->index != NULL) {
            free(p->index);
        }
        if (p->pp != NULL) {
            free(p->pp);
        }
        if (p->tt != NULL) {
            free(p->tt);
        }
        free(p);
    }
}