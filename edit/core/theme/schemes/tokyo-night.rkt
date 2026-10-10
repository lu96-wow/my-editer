#lang racket

;;; edit-rebuild/core/theme/schemes/tokyo-night.rkt —— Tokyo Night 配色（纯数据）
;;; 现代、和谐、低刺激。
;;;
;;; 说明：
;;;   keyword  语义色（少量关键字，保持一点饱和度以便一眼分辨；**不含红色**）
;;;   word     词着色前景（覆盖每个标识符，用**低饱和粉彩**，同族明度，避免刺眼；**不含红 / 粉**）
;;;   bracket  括号深度背景（8 层，同明度、仅色相微差，深色不抢字；**不含红**）

(require "../scheme.rkt"
         "../style.rkt")

(provide tokyo-night)

(define tokyo-night
  (scheme (rgb 192 202 245)
          ;; keyword：def / control / macro / binding / module
          (vector (rgb 187 154 247)   ; def      purple
                  (rgb 158 206 106)   ; control  green（原红，换成绿）
                  (rgb 224 175 104)   ; macro    yellow
                  (rgb 125 207 255)   ; binding  cyan
                  (rgb 122 162 247))  ; module   blue
          ;; word：12 色粉彩，明度接近、饱和度压低，长文档也不花；不用红 / 粉。
          (vector (rgb 230 194 158)   ; 杏
                  (rgb 216 204 152)   ; 沙
                  (rgb 184 210 160)   ; 鼠尾草
                  (rgb 162 212 172)   ; 叶绿
                  (rgb 152 214 202)   ; 薄荷
                  (rgb 142 206 226)   ; 水蓝
                  (rgb 150 196 236)   ; 天蓝
                  (rgb 166 182 236)   ; 长春花
                  (rgb 196 172 234)   ; 薰衣草
                  (rgb 206 172 226)   ; 兰紫
                  (rgb 188 178 214)   ; 藕荷
                  (rgb 178 198 214))  ; 钢青
          ;; bracket：8 层深度背景，深色低饱和，仅色相区分；不用红。
          (vector (rgb 36 40 58)      ; 0 靛蓝
                  (rgb 28 47 49)      ; 1 青灰
                  (rgb 48 46 30)      ; 2 橄榄
                  (rgb 30 49 40)      ; 3 松绿
                  (rgb 42 34 58)      ; 4 紫罗兰
                  (rgb 34 44 58)      ; 5 石板
                  (rgb 38 48 34)      ; 6 苔绿
                  (rgb 44 38 54))))   ; 7 藕紫
