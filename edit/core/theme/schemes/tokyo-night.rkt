#lang racket

;;; edit-rebuild/core/theme/schemes/tokyo-night.rkt —— Tokyo Night 配色（纯数据）
;;; 现代、和谐、低刺激。
;;;
;;; 说明：
;;;   keyword  语义色（少量关键字，保持一点饱和度以便一眼分辨）
;;;   word     词着色前景（覆盖每个标识符，用**低饱和粉彩**，同族明度，避免刺眼）
;;;   bracket  括号深度背景（8 层，同明度、仅色相微差，深色不抢字）

(require "../scheme.rkt"
         "../style.rkt")

(provide tokyo-night)

(define tokyo-night
  (scheme (rgb 192 202 245)
          ;; keyword：def / control / macro / binding / module
          (vector (rgb 187 154 247)   ; def      purple
                  (rgb 247 118 142)   ; control  red
                  (rgb 224 175 104)   ; macro    yellow
                  (rgb 125 207 255)   ; binding  cyan
                  (rgb 122 162 247))  ; module   blue
          ;; word：12 色粉彩，明度接近、饱和度压低，长文档也不花。
          (vector (rgb 226 170 180)   ; 玫瑰
                  (rgb 228 190 152)   ; 杏
                  (rgb 216 204 152)   ; 沙
                  (rgb 184 210 160)   ; 鼠尾草
                  (rgb 156 214 196)   ; 薄荷
                  (rgb 148 200 232)   ; 天蓝
                  (rgb 166 182 236)   ; 长春花
                  (rgb 196 172 234)   ; 薰衣草
                  (rgb 214 168 220)   ; 兰紫
                  (rgb 202 180 202)   ; 藕荷
                  (rgb 210 180 158)   ; 陶土
                  (rgb 178 198 214))  ; 钢青
          ;; bracket：8 层深度背景，深色低饱和，仅色相区分。
          (vector (rgb 36 40 58)      ; 0 靛蓝
                  (rgb 30 48 48)      ; 1 青灰
                  (rgb 50 45 30)      ; 2 橄榄
                  (rgb 54 36 44)      ; 3 梅
                  (rgb 40 34 58)      ; 4 紫罗兰
                  (rgb 52 42 34)      ; 5 褐
                  (rgb 34 50 42)      ; 6 苔绿
                  (rgb 48 38 54))))   ; 7 藕紫
