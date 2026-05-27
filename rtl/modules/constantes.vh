//Memoria de parametros (2048Kb), bases de address (Word addresses)
//Diseño INTERLEAVED optimizado para 4 MACs en paralelo

parameter general_input_scale       = 11'h000; // Word 0
parameter general_input_zp          = 11'h001; // Word 1 (Byte 0)
parameter general_right_shift       = 11'h001; // Word 1 (Byte 1)


parameter conv1_channel_in          = 1;
parameter conv1_channel_out         = 8;
parameter conv1_weights             = 11'h002; // Word 2
parameter conv1_bias                = 11'h014; // Word 20
parameter conv1_requant_multiplier  = 11'h01C; // Word 28
parameter conv1_output_zp           = 11'h024; // Word 36

parameter conv2_channel_in          = 8;
parameter conv2_channel_out         = 16;
parameter conv2_weights             = 11'h026; // Word 38
parameter conv2_bias                = 11'h146; // Word 326
parameter conv2_requant_multiplier  = 11'h156; // Word 342
parameter conv2_output_zp           = 11'h166; // Word 358

parameter conv3_channel_in          = 16;
parameter conv3_channel_out         = 32;
parameter conv3_weights             = 11'h16A; // Word 362
parameter conv3_bias                = 11'h5EA; // Word 1514
parameter conv3_requant_multiplier  = 11'h60A; // Word 1546
parameter conv3_output_zp           = 11'h62A; // Word 1578

parameter fc_out_channel_in          = 32;
parameter fc_out_channel_out         = 10;
parameter fc_out_weights            = 11'h632; // Word 1586
parameter fc_out_bias               = 11'h692; // Word 1682
parameter fc_out_requant_multiplier = 11'h69C; // Word 1692
parameter fc_out_output_zp          = 11'h6A6; // Word 1702
