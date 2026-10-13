#lang racket

;;; edit-rebuild/core/theme/tree.rkt —— 文件树配色（纯数据：face -> style）
;;;
;;; 树是一篇只读 document，face 按**整行**填（document-face-fill-batch），
;;; 所以这里只需给每个 face 一个颜色，不需要分段结构。
;;; face 词汇对齐 lab-rebuild/builtin/tree.rkt：dir / file / link / hidden / open。

(require "style.rkt")

(provide tree-faces)

(define tree-faces
  (hash 'tree-dir     (style (rgb 120 180 240) #f '())          ; 目录：蓝
        'tree-file    (style (rgb 200 200 200) #f '())          ; 文件：灰白
        'tree-link    (style (rgb 120 200 200) #f '())          ; 符号链接：青
        'tree-hidden  (style (rgb 120 120 130) #f '())          ; 隐藏项：暗
        'tree-open    (style (rgb 120 210 130) #f '(bold))      ; 已打开：绿粗
        'tree-match   (style (rgb 220 190 120) #f '())          ; 查询命中：黄
        'tree-current (style (rgb 20 20 20) (rgb 230 200 90) '())))  ; 当前命中：黄底
