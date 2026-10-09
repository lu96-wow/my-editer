#lang racket

;;; edit/theme/state.rkt —— 状态窗口配色（纯数据：face -> style）
;;;
;;; 对应 feature/status.rkt、feature/buffers.rkt、feature/prompt.rkt 里的 face。

(require "style.rkt")

(provide state-faces)

(define state-faces
  (hash 'status-bar   (style (rgb 225 225 225) (rgb 40 44 52) '())      ; 状态行
        'status-mode  (style (rgb 120 210 130) #f '(bold))              ; 模式 / 文档名
        'status-dirty (style (rgb 230 160 90) #f '(bold))              ; 未保存标记
        'message      (style (rgb 230 160 90) #f '())                  ; 提示 / 错误
        'buf-current  (style (rgb 120 210 130) #f '(bold))             ; buffers：当前文档
        'buf-file     (style (rgb 200 200 200) #f '())                 ; buffers：其它文档
        'buf-untitled (style (rgb 170 170 170) #f '())                 ; buffers：无路径
        'buf-view     (style (rgb 140 160 190) #f '())                 ; buffers：视图行
        'buf-dirty    (style (rgb 230 160 90) #f '(bold))              ; buffers：脏文档
        'log          (style (rgb 240 130 130) #f '())                 ; 日志行
        'input        (style (rgb 20 20 20) (rgb 230 200 90) '())    ; 输入行
        'complete     (style (rgb 200 200 200) #f '())              ; 补全候选
        'complete-selected (style (rgb 20 20 20) (rgb 120 180 240) '())))   ; 补全选中
