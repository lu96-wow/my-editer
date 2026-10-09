#lang racket

;;; edit/theme/schemes/nord.rkt —— Nord 配色（纯数据）
;;; 冷、低饱和、耐看。

(require "../scheme.rkt"
         "../style.rkt")

(provide nord)

(define nord
  (scheme (rgb 216 222 233)
          (vector (rgb 180 142 173)   ; def      nord15
                  (rgb 191 97 106)    ; control  nord11
                  (rgb 235 203 139)   ; macro    nord13
                  (rgb 136 192 208)   ; binding  nord8
                  (rgb 129 161 193))  ; module   nord9
          (vector (rgb 136 192 208) (rgb 163 190 140) (rgb 235 203 139)
                  (rgb 208 135 112) (rgb 180 142 173) (rgb 129 161 193))
          (vector (rgb 51 59 76) (rgb 48 60 58) (rgb 59 56 41) (rgb 58 51 63))))
