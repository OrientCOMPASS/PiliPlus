//
// Created by gutou on 2017/5/5.
//

#ifndef XL_XL_MODEL_BALL_H
#define XL_XL_MODEL_BALL_H
#include "../xl_types/xl_video_render_types.h"

xl_model * model_ball_create();
xl_model * model_planet_create();
xl_model * model_architecture_create();
xl_model * model_expand_create();

/** 【PiliPlus 扩展】直接设置垂直视场角（度）。上游只有 static 的 updateFov。 */
void xl_model_set_fovy(xl_model *model, GLfloat fovy);

#endif //XL_XL_MODEL_BALL_H
