//
// Created by 晓龙同学 on 2017/4/12.
//

#ifndef XL_XL_MESH_FACTORY_H
#define XL_XL_MESH_FACTORY_H

typedef struct {
    float* pp;
    float* tt;
    unsigned int * index;
    int ppLen, ttLen, indexLen;
} xl_mesh;


/**
 * 【PiliPlus 扩展】设置球面网格的投影参数，必须在 createModel() **之前**调用。
 * @param coverage_deg 水平覆盖角：360 或 180
 * @param u0,u1        单眼在贴图上的 u 区间（左右布局时取 [0,.5] 或 [.5,1]）
 * @param v0,v1        单眼在贴图上的 v 区间（上下布局时取 [.5,1] 或 [0,.5]）
 * 默认 (360, 0,1, 0,1) 与上游 get_ball_mesh() 完全一致。
 */
void xl_mesh_set_projection(float coverage_deg, float u0, float u1, float v0, float v1);

xl_mesh *get_ball_mesh();
xl_mesh *get_rect_mesh();
xl_mesh *get_planet_mesh();
xl_mesh *get_distortion_mesh(int eye);

void free_mesh(xl_mesh *p);

#endif //XL_XL_MESH_FACTORY_H
