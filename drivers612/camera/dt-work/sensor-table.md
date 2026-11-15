| label | node | type | bus | cell-index | cci-master | csiphy-sd-index | addr | regulators (V) | TLMM gpios | links / mclk |
|---|---|---|---|---|---|---|---|---|---|---|
| ois_rear | qcom,ois@62 | ois | i2c@990000 | 0 | - | - | 0xc4 | cam_vio=pm8350c_l2 1.800; cam_vaf=s2mpb03_0_l7 2.800 | MCU_RESET0=45, MCU_VANA=11, MCU_BOOT0=46 |  status="ok" |
| sensor_rear_wide | qcom,cam-sensor0 | cam-sensor | qcom,cci0 | 0 | 0 | 0 | - | cam_vdig=s2mpb03_0_l2 1.100; cam_vio=s2mpb03_0_l3 1.800; cam_vana=s2mpb03_0_l5 2.800; cam_vaf=s2mpb03_0_l7 2.800; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK0=64, CAM_RESET0=20, CAM_VANA0=11 | eeprom=eeprom0 actuator=actuator_rear0 ois=ois_rear led-flash=led_flash_rear mclk=19200000 camcc:92 status="ok" |
| actuator_rear0 | qcom,actuator@0xC | actuator | qcom,cci1 | 0 | 1 | - | 0x18 | cam_vio=s2mpb03_0_l3 1.800; cam_vaf=s2mpb03_0_l7 2.800 |  |  |
| eeprom4 | qcom,eeprom@0x3F | eeprom | qcom,cci1 | 4 | 0 | 2 | 0x7e | cam_vdig=s2mpb03_0_l4 1.200; cam_vio=s2mpb03_0_l3 1.800; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK3=67, CAM_RESET3=78, CAM_VANA1=14 |  mclk=24000000 camcc:98 status="ok" |
| eeprom3 | qcom,eeprom@37 | eeprom | qcom,cci1 | 3 | 0 | 1 | 0x6e | cam_vio=s2mpb03_0_l3 1.800; cam_vdig=s2mpb03_0_l4 1.200; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK1=65, CAM_RESET1=21, CAM_VANA1=14 |  mclk=24000000 camcc:94 status="ok" |
| eeprom2 | qcom,eeprom@0x2D | eeprom | qcom,cci1 | 2 | 0 | 2 | 0x5a | cam_vio=s2mpb03_0_l3 1.800; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK2=66, CAM_RESET2=77, CAM_VANA2=15 |  mclk=24000000 camcc:96 status="ok" |
| eeprom1 | qcom,eeprom@51 | eeprom | qcom,cci1 | 1 | 1 | - | 0xa2 | cam_vio=s2mpb03_0_l3 1.800 |  |  |
| eeprom0 | qcom,eeprom@50 | eeprom | qcom,cci1 | 0 | 1 | - | 0xa0 | cam_vaf=s2mpb03_0_l7 2.800; cam_vio=s2mpb03_0_l3 1.800 |  |  |
| sensor_rear_macro | qcom,cam-sensor4 | cam-sensor | qcom,cci1 | 4 | 0 | 3 | - | cam_vdig=s2mpb03_0_l4 1.200; cam_vio=s2mpb03_0_l3 1.800; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK3=67, CAM_RESET3=78, CAM_VANA1=14 | eeprom=eeprom4 led-flash=led_flash_rear mclk=24000000 camcc:98 status="ok" |
| sensor_front_full | qcom,cam-sensor13 | cam-sensor | qcom,cci1 | 13 | 0 | 4 | - | cam_vdig=s2mpb03_0_l1 1.050; cam_vio=s2mpb03_0_l3 1.800; cam_vana=s2mpb03_0_l6 2.900; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK4=68, CAM_RESET4=79 | eeprom=eeprom1 mclk=24000000 camcc:100 status="ok" |
| sensor_front | qcom,cam-sensor1 | cam-sensor | qcom,cci1 | 1 | 0 | 4 | - | cam_vdig=s2mpb03_0_l1 1.050; cam_vio=s2mpb03_0_l3 1.800; cam_vana=s2mpb03_0_l6 2.900; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK4=68, CAM_RESET4=79 | eeprom=eeprom1 mclk=24000000 camcc:100 status="ok" |
| sensor_rear_uw | qcom,cam-sensor2 | cam-sensor | qcom,cci1 | 2 | 0 | 2 | - | cam_vio=s2mpb03_0_l3 1.800; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK2=66, CAM_RESET2=77, CAM_VANA2=15 | eeprom=eeprom2 mclk=19200000 camcc:96 status="ok" |
| sensor_rear_tele | qcom,cam-sensor3 | cam-sensor | qcom,cci1 | 3 | 0 | 1 | - | cam_vdig=s2mpb03_0_l4 1.200; cam_vio=s2mpb03_0_l3 1.800; cam_clk=cam_cc_titan_top_gdsc  | CAMIF_MCLK1=65, CAM_RESET1=21, CAM_VANA1=14 | eeprom=eeprom3 mclk=24000000 camcc:94 status="ok" |

| s2mpb03_0_l7 | s2mpb03-ldo7 | "CAM0_s2mpb03-l7" | 2800000 | 2800000 |
| s2mpb03_0_l6 | s2mpb03-ldo6 | "CAM0_s2mpb03-l6" | 2900000 | 2900000 |
| s2mpb03_0_l5 | s2mpb03-ldo5 | "CAM0_s2mpb03-l5" | 2800000 | 2800000 |
| s2mpb03_0_l4 | s2mpb03-ldo4 | "CAM0_s2mpb03-l4" | 1200000 | 1200000 |
| s2mpb03_0_l3 | s2mpb03-ldo3 | "CAM0_s2mpb03-l3" | 1800000 | 1800000 |
| s2mpb03_0_l2 | s2mpb03-ldo2 | "CAM0_s2mpb03-l2" | 1100000 | 1100000 |
| s2mpb03_0_l1 | s2mpb03-ldo1 | "CAM0_s2mpb03-l1" | 1050000 | 1050000 |
